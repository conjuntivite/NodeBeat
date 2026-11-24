# Switches pela API do UniFi — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trazer do controlador UniFi Network os dados ricos de cada switch e os eventos do System Log para a tela do switch e para a tela de Eventos.

**Architecture:**
- Um módulo `backend/nodebeat/unifi.py` concentra o cliente HTTP e os parsers puros.
- Uma tarefa nova do worker (`run_unifi`) grava o estado por switch no Redis e os eventos na coleção `eventos`.
- A API devolve isso no detalhe do equipamento e numa rota nova de eventos de switch.
- O Flutter mostra tudo nas duas telas.

**Tech Stack:** FastAPI, motor/Mongo, redis.asyncio, httpx; Flutter web (`material_ui`, tokens gerados em `lib/theme/tokens.g.dart`, casca em `lib/widgets/shell.dart`).

**Spec:** `docs/superpowers/specs/2026-11-24-unifi-switches-design.md`

## Global Constraints

- `NODEBEAT_UNIFI_URL` e `NODEBEAT_UNIFI_API_KEY` são opcionais. Sem as duas, nada de UniFi roda e nada quebra.
- A chave é segredo:
  - nunca em log, mensagem de erro, resposta da API, Redis ou Mongo;
  - em log, só `type(e).__name__`;
  - o cabeçalho é `X-API-Key`.
- TLS do controlador: `verify=False` só no cliente do UniFi, com comentário `# ponytail:` explicando o certificado autoassinado interno.
- Amostras de teste só com valores falsos:
  - IP: 192.0.2.x e 198.51.100.x;
  - MAC: `02:00:00:..`;
  - nomes inventados;
  - nunca IP, MAC ou nome real.
- Eventos do UniFi:
  - nunca vão para o webhook;
  - não aparecem no `/api/eventos/painel` das MKs (que já exclui `mk_id` começando com `eq:`).
- Backend: testes com `.venv/Scripts/python -m pytest -q` a partir de `backend/`. Frontend: `/c/src/flutter/bin/flutter test` e `flutter analyze` limpo.
- UI:
  - só tokens (`tokensOf(context)`, `TradeType.*`);
  - componentes de `widgets/shell.dart` e `widgets/common.dart` (`TradeCard(titulo:)`, `Indicador`, `Selo`, `AbasPilula`);
  - dois temas, texto ≥ 4,5:1;
  - textos em pt-BR.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Campo ausente ou com tipo estranho no JSON do UniFi:
   - `poe_power` vem como string;
   - `general_temperature` pode não existir;
   - `system-stats` com strings;
   - cliente sem `ip`.

   Nada levanta exceção; o valor vira `None` e a tela mostra "—".
2. Controlador fora do ar, 401 ou timeout: a rodada termina sem exceção, mantém o último estado gravado e loga só o nome da exceção.
3. O mesmo evento lido em duas rodadas (o cursor sobrepõe) não duplica (índice único em `unifi_id`).
4. Porta com 30 clientes (uplink): o detalhe não estoura a tela (lista rolável, contagem visível).
5. Switch do UniFi sem equipamento cadastrado com o mesmo IP: ignorado, sem erro.

---

### Task 1: Cliente e parsers de dispositivo e clientes (`unifi.py`) + configuração

**Files:**
- Create: `backend/nodebeat/unifi.py`
- Modify: `backend/nodebeat/config.py` (campos `unifi_url: str | None = None` e `unifi_api_key: str | None = None` no fim de `Settings`, lidos de `NODEBEAT_UNIFI_URL`/`NODEBEAT_UNIFI_API_KEY` em `load_settings`, vazio → `None`), `deploy/compose.yml` (passar as duas variáveis só ao serviço `worker`, com `${VAR:-}`), `deploy/.env.example` (linhas vazias comentadas)
- Test: `backend/tests/test_unifi.py`

**Interfaces:**
- Produces:
  - `parse_switch(dev: dict) -> dict` devolve:

    ```
    {"ip", "mac", "nome", "modelo",
     "sistema": {"modelo", "firmware", "atualizacao": bool, "uptime_s": int|None,
                 "cpu": float|None, "mem": float|None, "temperatura": float|None,
                 "poe_usado_w": float|None, "poe_max_w": float|None, "clientes": int|None,
                 "uplink": {"porta": int, "remoto": str|None, "remoto_porta": int|None} | None},
     "portas": {"<port_idx>": {"poe_w": float|None, "poe_classe": str|None,
                               "rx_mbps": float|None, "tx_mbps": float|None,
                               "erros": int, "descartes": int, "stp": str|None,
                               "quedas_link": int|None, "uplink": bool,
                               "aparelhos": int|None, "clientes": []}}}
    ```

  - `clientes_com_fio(sta: list[dict]) -> dict[str, dict[int, list[dict]]]`: `sw_mac` minúsculo → `sw_port` → lista de `{"nome": str|None, "ip": str|None, "mac": str, "fabricante": str|None, "mbps": int|None}`, ordenada por nome e depois IP.
  - `async ler(client: httpx.AsyncClient, url: str, chave: str, caminho: str, corpo: dict | None = None) -> Any`: GET sem corpo, POST com corpo; devolve `json()["data"]` quando a resposta tem `data`, senão o JSON. Erros HTTP propagam como `UnifiErro` (classe nova, mensagem genérica "UniFi não respondeu", sem URL nem chave).

- [ ] **Step 1:** Write failing tests in `test_unifi.py`:
  - `test_parse_switch_poe` (porta com `poe_power: "2.50"` → `poe_w == 2.5`, arredondado com `round(x, 1)`);
  - `rx_bytes-r: 1250000.0` → `rx_mbps == 10.0`;
  - `rx_errors+tx_errors` somados em `erros`, `rx_dropped+tx_dropped` em `descartes`;
  - `system-stats {"cpu": "16.0"}` → `cpu == 16.0`;
  - `test_parse_switch_campos_ausentes` (dict só com `ip`, `mac`, `name`, `port_table: [{"port_idx": 1}]` → nada levanta; `poe_w is None`, `temperatura is None`, `uplink is None`);
  - `test_clientes_com_fio`: só `is_wired`; nome = `hostname` ou `name`, e `None` quando igual ao MAC; `ip` cai para `last_ip`; agrupa por `sw_mac` minúsculo/`sw_port`; cliente sem `sw_port` é ignorado;
  - `test_ler_envia_chave_e_nao_vaza` (com `httpx.MockTransport`: confere o header `X-API-Key`; resposta 401 → `UnifiErro` cujo `str` não contém a chave nem a URL);
  - `test_settings_unifi_opcional` (sem as variáveis → `None`).
- [ ] **Step 2:** Run `pytest tests/test_unifi.py -q` → FAIL.
- [ ] **Step 3:** Implement. Bytes/s → Mbps = `round(b * 8 / 1e6, 1)`. Conversões tolerantes: um helper `_num(v) -> float|None` que aceita `int`, `float` e `str` numérica.
- [ ] **Step 4:** Run full backend suite → PASS.
- [ ] **Step 5:** Commit `feat(unifi): cliente e leitura de switches e clientes do controlador`.

### Task 2: Eventos do System Log → documentos de evento

**Files:**
- Modify: `backend/nodebeat/unifi.py`
- Test: `backend/tests/test_unifi.py`

**Interfaces:**
- Consumes: nada de outras tarefas.
- Produces:
  - `TIPOS = {"CLIENT_CONNECTED_WIRED": "cliente_conectou", "CLIENT_DISCONNECTED_WIRED": "cliente_desconectou", "DEVICE_UNREACHABLE": "inalcancavel", "MULTIPLE_DEVICES_UNREACHABLE": "inalcancavel", "DEVICE_RECONNECTED": "reconectou", "DEVICE_RECONNECTED_WITH_DOWNLINKS": "reconectou", "POWER_SUPERVISOR_POWER_CYCLE_TRIGGERED": "poe_religado", "PORT_TRANSMISSION_ERRORS": "erros_transmissao", "MADE_CHANGES": "mudanca_admin", "CLIENT_IP_CONFLICT": "conflito_ip"}`; os demais viram `"outro"`.
  - `GRUPOS = {"cliente_conectou": "clientes", "cliente_desconectou": "clientes", "inalcancavel": "alertas", "reconectou": "alertas", "erros_transmissao": "alertas", "conflito_ip": "alertas", "poe_religado": "poe", "mudanca_admin": "mudancas", "outro": "alertas"}`.
  - `switch_do_evento(ev: dict, switches: list[dict]) -> dict | None`: `switches` = itens `{"id", "nome", "mac"}`. Casa quando:
    - algum `parameters[*]["id"]`, em minúsculas, é o MAC do switch; ou
    - `parameters.DEVICE.name` ou `parameters.OBJECT.name` é igual ao nome; ou
    - `parameters.DEVICE_WITH_PORT.name` começa com o nome seguido de espaço.
  - `evento_unifi(ev: dict, eq_id: str) -> dict` devolve:

    ```
    {"mk_id": "eq:<eq_id>", "origem": "unifi", "unifi_id": ev["id"],
     "recebido_em": datetime UTC de ev["timestamp"] ms,
     "tipo": TIPOS..., "severidade": ev.get("severity","").lower() or None,
     "campos": {"porta": int|None, "cliente": str|None, "ip": str|None, "duracao": str|None,
                "dados_up": str|None, "dados_down": str|None},
     "mensagem": str pt-BR}
    ```

  - Mensagens (exatas):
    - `cliente_conectou`: `"{cliente} conectou na porta {porta} ({velocidade})"`, sem o parêntese quando não houver velocidade;
    - `cliente_desconectou`: `"{cliente} desconectou da porta {porta} · {duracao} · ↓ {dados_down} ↑ {dados_up}"`, omitindo as partes ausentes;
    - `inalcancavel`: `"Switch inalcançável"`;
    - `reconectou`: `"Switch reconectou"`;
    - `poe_religado`: `"PoE religado automaticamente na porta {porta}"`, ou sem "na porta …" se não houver porta;
    - `erros_transmissao`: `"Erros de transmissão na porta {porta}"`;
    - `mudanca_admin`: `"{admin} alterou a configuração"`;
    - `conflito_ip`: `"Conflito de IP: {ip}"`;
    - `outro`: o `message_raw` com `{CHAVE}` trocado por `parameters[CHAVE].name`.
  - O `cliente` é `parameters.CLIENT.name`, a `porta` vem de `int(parameters.PORT.name)` e o `admin` de `parameters.ADMIN.name`.
- [ ] **Step 1:** Failing tests com eventos sanitizados (um por tipo, mais um desconhecido). Cobrir:
  - `switch_do_evento` pelos três caminhos e o `None`;
  - a mensagem exata de cada tipo;
  - porta não numérica → `None`;
  - `timestamp` → datetime aware UTC.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** Suite PASS. **Step 5:** Commit `feat(unifi): eventos do System Log dos switches`.

### Task 3: Tarefa `run_unifi` no worker

**Files:**
- Modify: `backend/nodebeat/worker.py`, `backend/nodebeat/store.py` (`async def garantir_indice_unifi(db)`: índice único parcial em `eventos.unifi_id`, com `partialFilterExpression={"unifi_id": {"$exists": True}}`; `async def inserir_eventos_unifi(db, docs) -> int`: `insert_many(ordered=False)` ignorando `BulkWriteError` de duplicata, devolve quantos entraram)
- Test: `backend/tests/test_worker_unifi.py`

**Interfaces:**
- Consumes: Task 1 (`ler`, `parse_switch`, `clientes_com_fio`, `UnifiErro`), Task 2 (`switch_do_evento`, `evento_unifi`); `store.listar_equipamentos(db, tipo="switch")`.
- Produces:
  - `async run_unifi(db, r, settings, now, *, ler=unifi.ler) -> None`, que nunca levanta.
  - Grava o Redis `unifi:eq:<id>` = `json.dumps({"lido_em": now.isoformat(), "sistema": ..., "portas": ...})`, com `clientes` preenchido por porta a partir de `clientes_com_fio[mac_do_switch]`.
  - Grava o cursor `unifi:log:ultimo_ms`.
- [ ] **Step 1:** Failing tests, com `ler` falso por caminho:
  - (a) sem `unifi_url`/`unifi_api_key` → nenhuma chamada;
  - (b) casa o switch pelo IP e grava o estado, com os clientes na porta certa; switch do UniFi sem equipamento é ignorado;
  - (c) os eventos que citam o switch entram em `eventos` com `mk_id "eq:<id>"`; rodar duas vezes com o mesmo log não duplica; eventos de AP (sem switch) ficam fora;
  - (d) `ler` levanta `UnifiErro` → sem exceção, o estado anterior fica intacto e o log não contém a chave;
  - (e) na 1ª vez, `timestampFrom = now - 24 h`; depois, o maior `timestamp` lido menos 60 000 ms de sobreposição.

  O log é lido por `POST /proxy/network/v2/api/site/default/system-log/all` e `.../device-alert`, pageSize 500, até 5 páginas cada, parando quando a página vier com menos de 500.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. Em `main()`, coloque uma tarefa como `eq_task`, com relógio próprio a cada `s.mapa_s`, pulando se a anterior não terminou, e só se `s.unifi_url and s.unifi_api_key`. O cliente é `httpx.AsyncClient(verify=False, timeout=15)` com comentário `ponytail:`.
- [ ] **Step 4:** Suite PASS. **Step 5:** Commit `feat(worker): coleta do UniFi a cada minuto`.

### Task 4: API — `unifi` no detalhe do equipamento e `/api/eventos/switches`

**Files:**
- Modify: `backend/nodebeat/api.py`
- Test: `backend/tests/test_api_unifi.py`

**Interfaces:**
- Consumes: o Redis `unifi:eq:<id>` (Task 3) e os eventos `origem: "unifi"`.
- Produces:
  - `GET /api/equipamentos/{id}` ganha `"unifi": {"lido_em", "sistema", "portas": {<nome SNMP>: {...}}} | null`.
    - O nome SNMP casa pelo número no fim do nome da porta do estado (`re.search(r"(\d+)$")`).
    - Porta do UniFi sem par no SNMP entra com a chave `"Porta <idx>"`.
  - `GET /api/eventos/switches?periodo=1h|24h|7d|30d` (422 em outro valor), com o mesmo `auth` das outras rotas, devolve:

    ```
    {"contagens": {"clientes": n, "alertas": n, "poe": n, "mudancas": n},
     "eventos": [até 100, mais novos primeiro:
       {"quando": iso, "switch_id", "switch_nome", "porta", "tipo", "grupo", "mensagem", "severidade"}]}
    ```

    O `switch_nome` vem do equipamento, ou `"Switch removido"`.
- [ ] **Step 1:** Failing tests:
  - o mapeamento `0/12` ↔ idx 12;
  - `unifi: null` sem a chave no Redis;
  - nenhuma resposta contém `"api_key"` ou `"X-API-Key"`;
  - as contagens por grupo e a ordem;
  - o período filtra;
  - período inválido → 422;
  - `/api/eventos/painel` não conta os eventos unifi.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** Suite PASS. **Step 5:** Commit `feat(api): dados do UniFi no switch e eventos de switch`.

### Task 5: Flutter — tela do switch com os dados do UniFi

**Files:**
- Modify: `frontend/lib/api/client.dart` (`Equipamento.unifi` como `UnifiSwitch?`, com `sistema` e `portas`; modelos `UnifiPorta` e `UnifiCliente` com parsing tolerante; nulos viram null), `frontend/lib/screens/switch_detail.dart`
- Test: `frontend/test/switch_detail_test.dart`

**Interfaces:**
- Consumes: o JSON da Task 4.
- Produces:
  - **Indicadores**, quando `unifi != null`, depois dos atuais: `CPU` (`"16%"`), `Memória`, `Temperatura` (`"53 °C"`, ou omitido se null), `PoE` (`"51,0 W"` com dica `"de 195 W"`, omitido se null), `Clientes`.
  - O subtítulo ganha `Firmware 7.6.11`, mais `· atualização disponível` quando houver.
  - **Tabela de portas:** colunas novas `PoE`, `↓ / ↑`, `Erros`, `STP` e `Clientes` (com "—" quando não há dado), com vírgula decimal (`"2,5 W"`, `"10,0 / 0,4 Mbps"`). A tabela rola na horizontal, com largura mínima de 900.
  - **Detalhe da porta:**
    - linha de resumo com PoE e tráfego;
    - seção "Equipamentos nesta porta (N)", com cada cliente em uma linha: nome ou fabricante ou "Sem nome" em `heading4`, IP e MAC em `TradeType.ticker`, e `mbps`;
    - com mais de 8, uma lista rolável de altura máxima de 320;
    - na porta de uplink do `sistema.uplink`, a linha "Uplink para {remoto} (porta {remoto_porta})".
- [ ] **Step 1:** Failing widget tests:
  - os indicadores aparecem com `unifi` e somem sem ele;
  - a linha da porta 0/1 mostra `2,5 W` e `10,0 / 0,4 Mbps`;
  - tocar na 0/1 mostra o nome e o IP do cliente;
  - uma porta com 30 clientes mostra "Equipamentos nesta porta (30)", sem overflow em 360 px;
  - os temas claro e escuro sem exceção.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `flutter analyze` limpo + suíte PASS. **Step 5:** Commit `feat(painel): PoE, tráfego e equipamentos por porta do switch`.

### Task 6: Flutter — bloco Switches na tela de Eventos

**Files:**
- Modify: `frontend/lib/api/client.dart` (`Future<EventosSwitches> eventosSwitches(String periodo)`), `frontend/lib/screens/painel_eventos.dart`
- Test: `frontend/test/painel_eventos_test.dart`

**Interfaces:**
- Consumes: `/api/eventos/switches` (Task 4).
- Produces:
  - Abaixo do conteúdo das MKs, um `TradeCard(titulo: 'Switches')` com 4 `Indicador`: `Clientes com fio`, `Alertas`, `PoE religado`, `Mudanças`.
  - Abaixo deles, a lista: hora `HH:mm` (ou `dd/MM HH:mm` fora do dia), `"{switch_nome} · Porta {porta}"` (sem porta, só o nome) e a mensagem.
  - Selo por severidade: `high`/`critical` → negative, `medium` → warning, o resto → neutro (`fgSecondary`).
  - Vazio → "Nenhum evento de switch no período."; erro → texto em `negative`, sem derrubar o resto da tela.
  - Usa o mesmo período da página; os valores da tela 1h/24h/7d/30d são mapeados para o parâmetro da rota.
- [ ] **Step 1:** Failing tests:
  - o bloco aparece com os contadores e as linhas;
  - o estado vazio;
  - erro só no bloco;
  - 360 px sem overflow;
  - os dois temas.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** analyze + suíte PASS. **Step 5:** Commit `feat(painel): eventos dos switches na tela de Eventos`.

### Task 7: Deploy no CT 119

- [ ] Deploy `worker api web` (o syslog não muda): `git archive HEAD | ssh root@192.168.60.200 "pct exec 119 -- tar -x -C /opt/nodebeat"` + `docker compose -f deploy/compose.yml --env-file deploy/.env up -d --build worker api web </dev/null`.
- [ ] Conferir:
  - `unifi:eq:*` existe para os 2 switches, com portas e clientes;
  - existem eventos `origem: "unifi"`;
  - `/api/eventos/switches?periodo=24h` responde 200;
  - nenhum log do worker contém a chave (`docker logs nodebeat-worker-1 | grep -c "<prefixo de 6 caracteres da chave lido do .env, sem imprimir>"` = 0).

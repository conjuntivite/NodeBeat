# Inventário de rede das MKs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O NodeBeat lê de hora em hora as faixas, o IPsec, o NAT, os serviços e os IPs conectados de cada MK. Com isso, a equipe confere se uma faixa, uma porta ou um IP está livre antes de montar uma MK nova ou instalar um equipamento.

**Architecture:**
- **Lógica:** funções puras em `nodebeat/inventario.py` transformam as linhas cruas do RouterOS e fazem as conferências.
- **Leitura:** `routeros.fetch_inventario` lê tudo numa sessão. O worker roda essa leitura numa task separada do ciclo de 30 s e grava no Mongo (`inventario`, `ips_vistos`).
- **Painel:** a API expõe consultas e conferências. O Flutter ganha a tela "Faixas de IP" e as seções Portas/IPs no detalhe da MK.

**Tech Stack:** Python 3.12, FastAPI, motor/MongoDB, redis, librouteros, `ipaddress` (stdlib); Flutter web; pytest + mongomock-motor + fakeredis; flutter_test + `http/testing`.

**Spec:** `docs/superpowers/specs/2026-11-16-inventario-rede-design.md`

## Global Constraints

- O NodeBeat só lê as MKs. O usuário `monitor` (política `read,api`) basta. Não pedir permissão nova.
- RouterOS v6 (≥ 6.43) e v7. Campo ausente na linha vale como falso/vazio (v6 não manda `template`, `dynamic` às vezes etc.).
- Só stdlib para redes (`ipaddress`). Nenhuma dependência nova no backend nem no Flutter.
- Nunca logar `str(e)`/args de exceção (pode conter senha). Erros da MK viram `RouterOsError.detalhe`.
- IPs, nomes e dados reais nunca entram em código, testes, docs ou commits. Usar exemplos fictícios (`192.0.2.x`, `10.x`, `198.51.100.x`).
- Leitura do inventário a cada **3600 s** (`NODEBEAT_INVENTARIO_S`). Semáforo **próprio** de 10. Não roda com `engine.frozen` (falha da sede).
- Dados com mais de **2 h** (`lido_em`) ou nunca lidos geram "faltam dados".
- IP **em uso** = lease fixa (`dynamic` falso) **ou** visto nos últimos **15 dias**.
- Só redes de **túnel** e da **sede** bloqueiam faixa. As demais geram aviso.
- Redes da sede: `NODEBEAT_SEDE_REDES` (CIDRs separados por vírgula). CIDR inválido → `RuntimeError` no boot.
- Front-end: Trade UI (ler `C:/Users/User/design-systems/trade-ui/docs/brand-book.md`), só tokens de `TradeTokens`. `positive` para livre, `negative` para em uso, `warning` para avisos/faltam dados. Temas claro e escuro.
- Textos de UI e mensagens em pt-BR.

## Review Focus

1. **Linhas de MK v6 sem campos** (`template`, `dynamic`, `src-address-list`, `comment`, `to-ports` ausentes) → nada quebra, ausente = falso/vazio. Teste em Task 1 (`test_montar_linhas_v6_sem_campos`).
2. **CIDR digitado com bits de host ou sem prefixo** (`10.20.5.1/24`, `10.20.5.7`) → normaliza (`strict=False`; sem prefixo = /32). Lixo → 422. Teste em Task 1 e Task 3.
3. **`dst-port` em lista/faixa** (`80,443`, `8000-8010,9000`) e dst-nat sem `dst-port` → todas as portas. Teste em Task 1.
4. **IP que aparece na ARP e no lease ao mesmo tempo** → um registro só, `host_name`/`fixo` do lease. Teste em Task 1.
5. **Política IPsec com `src-address=0.0.0.0/0`** → não marca tudo como túnel (ignora /0). Teste em Task 1.

---

### Task 1: Lógica pura do inventário

**Files:**
- Create: `backend/nodebeat/inventario.py`
- Test: `backend/tests/test_inventario.py`

**Interfaces:**
- Produces (todas puras, sem I/O):
  - `LIMITE_LEITURA = timedelta(hours=2)`; `DIAS_EM_USO = 15`
  - `montar(raw: dict) -> dict`: `raw` tem as chaves `address`, `dhcp_network`, `pool`, `ipsec_policy`, `nat`, `service`, cada uma `list[dict]` com as linhas cruas do librouteros (chaves com hífen, ex.: `"src-address"`). Retorna:
    ```
    {"redes":   [{"rede": "192.168.10.0/24", "origem": "address"|"dhcp", "interface": str|None, "tunel": bool}],
     "ipsec":   [{"src": cidr, "dst": cidr}],
     "pools":   [{"nome": str, "ranges": str}],
     "nat":     [{"protocolo": str|None, "dst_port": str|None, "to_addresses": str|None, "to_ports": str|None,
                  "comentario": str, "ativo": bool, "aberto": bool}],
     "servicos":[{"nome": str, "porta": int, "ativo": bool, "aberto": bool}]}
    ```
  - `ips_vistos(lease: list[dict], arp: list[dict], redes: list[str]) -> list[dict]` → `[{"ip", "mac", "host_name": str|None, "fixo": bool}]`
  - `desatualizado(lido_em: datetime|None, agora: datetime) -> bool`
  - `sobreposicoes(mks: list[dict], sede: list[str]) -> list[dict]`. `mks` itens: `{"nome", "redes": [<itens de montar()["redes"]>]}`. Retorna `[{"a", "rede_a", "b", "rede_b"}]` (`b == "Sede"` para a sede).
  - `conferir_faixa(cidr: str, mks: list[dict], sede: list[str], agora: datetime) -> dict` → `{"faixa", "resultado": "livre"|"em_uso", "colisoes": [{"nome","rede"}], "avisos": [str], "faltam": [nome]}`. `mks` itens também têm `lido_em`. `ValueError` se o CIDR for inválido.
  - `porta_em(spec: str|None, porta: int) -> bool`
  - `conferir_porta(porta: int, protocolo: str, inv: dict) -> dict` → `{"porta", "protocolo", "resultado", "usos": [str], "avisos": [str]}`
  - `conferir_ip(ip: str, inv: dict, vistos: list[dict], agora: datetime) -> dict` → `{"ip", "resultado": "fora_da_faixa"|"em_uso"|"livre", "visto": dict|None, "avisos": [str]}`. `vistos` itens têm `ultimo_visto: datetime`. `ValueError` se o IP for inválido.

**Regras do `montar`:**
- `address`: ignora `disabled`, `dynamic` verdadeiros e prefixo /32; normaliza com `ip_network(addr, strict=False)`.
- `dhcp_network`: entra sempre.
- `ipsec_policy`: ignora `template`, `disabled` e `src` /0. `tunel` = rede `subnet_of` algum `src`.
- `nat`: só `action == "dst-nat"`; `aberto` = ativo e sem `src-address` e sem `src-address-list`.
- `service`: `aberto` = ativo e `address` vazio.

- [ ] **Step 1: Escrever os testes que falham** em `backend/tests/test_inventario.py`:
  - `test_montar_normaliza_e_marca_tunel`: address `192.168.10.1/24` em `bridge` + política `src-address=192.168.10.0/24 dst-address=10.1.0.0/16` → `redes == [{"rede":"192.168.10.0/24","origem":"address","interface":"bridge","tunel":True}]`, `ipsec == [{"src":"192.168.10.0/24","dst":"10.1.0.0/16"}]`.
  - `test_montar_ignora_dinamico_32_e_desativado`: três addresses (`dynamic=True`, `/32`, `disabled=True`) → `redes == []`.
  - `test_montar_linhas_v6_sem_campos`: address só com `address`/`interface`; política sem `template`/`disabled`; nat `{"action":"dst-nat","dst-port":"8081","to-addresses":"192.168.10.20"}` → não levanta; nat `aberto is True`, `comentario == ""`, `to_ports is None`.
  - `test_ipsec_src_0_0_0_0_ignorado`: política `src-address=0.0.0.0/0` → rede `192.168.10.0/24` com `tunel is False`.
  - `test_nat_aberto_e_restrito`: dst-nat com `src-address-list="sede"` → `aberto is False`; regra `action="masquerade"` não aparece.
  - `test_servico_aberto`: `{"name":"winbox","port":8291,"address":"","disabled":False}` → `aberto True`; com `address="10.1.0.0/16"` → `False`.
  - `test_ips_vistos_merge_e_filtra`: lease `192.168.10.20` (`host-name="dvr"`, `dynamic=False`) + arp do mesmo IP + arp `203.0.113.5` fora das redes → um único `{"ip":"192.168.10.20","mac":...,"host_name":"dvr","fixo":True}`.
  - `test_sobreposicao_so_tunel`: A e B com `10.30.0.0/24` túnel → 1 item; C e D com `192.168.1.0/24` não túnel → nenhum; A × sede `10.30.0.0/16` → item com `b == "Sede"`.
  - `test_conferir_faixa_livre_em_uso_aviso`: `10.30.0.128/25` contra túnel `10.30.0.0/24` → `em_uso`, colisão listada. `192.168.1.0/24` contra rede não túnel → `livre` com aviso contendo o nome do condomínio. `10.99.0.0/24` → `livre`, `avisos == []`.
  - `test_conferir_faixa_normaliza`: `"10.20.5.1/24"` → `faixa == "10.20.5.0/24"`; `"10.20.5.7"` → `"10.20.5.7/32"`; `"abc"` → `ValueError`.
  - `test_conferir_faixa_faltam`: MK com `lido_em=None` e outra com `agora - 3h` → as duas em `faltam`, resultado ainda `livre`.
  - `test_conferir_faixa_sede_vazia_avisa`: `sede=[]` → aviso `"Redes da sede não cadastradas"`.
  - `test_porta_em`: `porta_em("80,443",443)`, `porta_em("8000-8010,9000",8005)`, `porta_em(None,1)` verdadeiros; `porta_em("8000-8010",8011)` falso.
  - `test_conferir_porta`: inv com dst-nat tcp `8081` ativo, dst-nat `8090` desativado, serviço `winbox` 8291 ativo → 8081 `em_uso`; 8291 `em_uso` (uso cita `winbox`); 8090 `livre` com aviso de regra desativada; 8081 com `protocolo="udp"` → `livre`; dst-nat sem `protocolo` ocupa tcp e udp.
  - `test_conferir_ip`: redes `192.168.10.0/24`; pool `192.168.10.100-192.168.10.200`. `10.0.0.1` → `fora_da_faixa`. Visto há 3 dias → `em_uso`. Visto há 20 dias e `fixo=False` → `livre` com aviso "visto em DD/MM". Visto há 20 dias e `fixo=True` → `em_uso`. `192.168.10.150` nunca visto → `livre` com aviso de pool.

- [ ] **Step 2: Rodar e ver falhar.** Run: `cd backend; python -m pytest tests/test_inventario.py -q` → Expected: FAIL (ImportError `nodebeat.inventario`).

- [ ] **Step 3: Implementar `backend/nodebeat/inventario.py`** com as assinaturas acima. Pools: `ranges` pode ter vários intervalos separados por vírgula, cada um `a-b` ou um IP só. Comparação de IP com `ipaddress.ip_address`. Sem I/O.

- [ ] **Step 4: Rodar e ver passar.** Run: `cd backend; python -m pytest tests/test_inventario.py -q` → Expected: todos PASS.

- [ ] **Step 5: Commit.** `git add backend/nodebeat/inventario.py backend/tests/test_inventario.py; git commit -m "feat(inventario): lógica pura de faixas, portas e IPs"`

---

### Task 2: Leitura na MK, persistência e worker horário

**Files:**
- Modify: `backend/nodebeat/routeros.py` (nova `fetch_inventario`)
- Modify: `backend/nodebeat/store.py` (funções de inventário)
- Modify: `backend/nodebeat/config.py` (`inventario_s`, `sede_redes`)
- Modify: `backend/nodebeat/worker.py` (`atualizar_mk`, `run_inventario`, `inventario_devido`, loop)
- Modify: `deploy/compose.yml` (x-env), `deploy/.env.example`, `deploy/README.md`
- Test: `backend/tests/test_routeros.py`, `backend/tests/test_worker.py`, `backend/tests/test_app_from_env.py` (ou o teste de config que já exista)

**Interfaces:**
- Consumes: `inventario.montar`, `inventario.ips_vistos` (Task 1).
- Produces:
  - `routeros.fetch_inventario(host: str, user: str, password: str, pinned_sha256: str|None, timeout: float = 10.0) -> dict`: devolve o `raw` do `montar` mais as chaves `lease` e `arp`. Lê numa sessão via `_com_api`: `/ip/address/print`, `/ip/dhcp-server/network/print`, `/ip/pool/print`, `/ip/ipsec/policy/print`, `/ip/firewall/nat/print`, `/ip/service/print`, `/ip/dhcp-server/lease/print`, `/ip/arp/print`.
  - `Settings.inventario_s: int = 3600`, `Settings.sede_redes: list[str] = field(default_factory=list)` (no fim do dataclass; `SET` posicional dos testes continua valendo). Variáveis: `NODEBEAT_INVENTARIO_S`, `NODEBEAT_SEDE_REDES`. Cada CIDR é validado e normalizado com `ip_network(strict=False)`; inválido → `RuntimeError("NODEBEAT_SEDE_REDES inválida")`.
  - store:
    - `salvar_inventario(db, mk_id: str, doc: dict, lido_em: datetime) -> None`: upsert em `inventario` com `{mk_id, **doc, lido_em, erro: None}`.
    - `inventario_erro(db, mk_id: str, detalhe: str) -> None`: upsert só do `erro`; mantém dados e `lido_em` anteriores.
    - `get_inventario(db, mk_id) -> dict|None`; `listar_inventarios(db) -> list[dict]`.
    - `registrar_ips(db, mk_id: str, ips: list[dict], quando: datetime) -> None`: `$set` mac/host_name/fixo/ultimo_visto, `$setOnInsert` primeiro_visto. Garante índice único `(mk_id, ip)`.
    - `listar_ips(db, mk_id) -> list[dict]`: ordenado por `ipaddress.ip_address(ip)`.
    - `esquecer_ip(db, mk_id, ip) -> bool`.
    - `apagar_inventario(db, mk_id) -> None`: apaga das duas coleções.
    - Documentos saem sem `_id`.
  - worker:
    - `atualizar_mk(db, settings, mk: dict, now: datetime, fetch=routeros.fetch_inventario) -> str|None`: decripta a senha, roda `fetch` via `asyncio.to_thread`, grava inventário + IPs; devolve `None` em sucesso ou o detalhe do erro (já gravado com `inventario_erro`). Exceção desconhecida vira `"Resposta inesperada da API"` e só loga `type(e).__name__`.
    - `run_inventario(db, settings, now, *, fetch=routeros.fetch_inventario) -> None`: todas as MKs, `asyncio.Semaphore(10)` próprio, erro de uma não para as outras.
    - `inventario_devido(ultimo: float|None, agora: float, intervalo: int, pedido: bool) -> bool`.
    - Chave Redis `"inventario:pedido"` (constante `PEDIDO_INVENTARIO` em `worker.py`).

- [ ] **Step 1: Testes que falham.**
  - `test_routeros.py::test_fetch_inventario_le_todos_os_menus`: `FakeApi` (já existe no arquivo) devolvendo uma linha por caminho → o resultado tem as 8 chaves; a conexão é fechada.
  - `test_worker.py::test_inventario_grava_e_mantem_em_falha`: 1ª chamada com `fetch` ok grava `redes` e IPs; 2ª com `fetch` levantando `RouterOsError("API sem resposta (timeout)")` → `erro` preenchido, `redes` e `lido_em` da 1ª preservados.
  - `test_worker.py::test_ip_nao_some_e_primeiro_visto_fixo`: IP visto em T0 e ausente em T0+1h → continua em `listar_ips`, `primeiro_visto == T0`. Visto de novo em T0+2h → `ultimo_visto` atualizado, `primeiro_visto` igual.
  - `test_worker.py::test_inventario_uma_mk_falha_outras_gravam`: 2 MKs, uma levanta `ValueError` → a outra gravada; a com erro tem `erro == "Resposta inesperada da API"`.
  - `test_worker.py::test_inventario_devido`: `(None,0,3600,False)` → True; `(0,100,3600,False)` → False; `(0,100,3600,True)` → True; `(0,3600,3600,False)` → True.
  - `test_worker.py::test_listar_ips_ordem_numerica`: `192.168.10.9` antes de `192.168.10.10`.
  - Config: `NODEBEAT_SEDE_REDES="10.1.0.1/16, 10.2.0.0/24"` → `["10.1.0.0/16","10.2.0.0/24"]`; `"xyz"` → `RuntimeError`; ausente → `[]`.

- [ ] **Step 2: Rodar e ver falhar.** `cd backend; python -m pytest tests/test_routeros.py tests/test_worker.py tests/test_app_from_env.py -q` → FAIL nos testes novos.

- [ ] **Step 3: Implementar** routeros, config, store e worker conforme as interfaces. No `main()`:
  - Guardar `inv_task` e `ultimo_inv` (tempo do loop).
  - A cada volta, depois de `run_cycle`: `pedido = bool(await r.getdel(PEDIDO_INVENTARIO))`. Se `not engine.frozen` e (`inv_task is None or inv_task.done()`) e `inventario_devido(ultimo_inv, loop.time(), s.inventario_s, pedido)`, criar a task `run_inventario(db, s, datetime.now(UTC))` e atualizar `ultimo_inv`.
  - Se `pedido` chegar com a task rodando ou com a sede congelada, devolver o pedido ao Redis (`set`) para não perder.
  - A task nunca bloqueia o ciclo de 30 s.

- [ ] **Step 4: Deploy.**
  - Em `deploy/compose.yml` (bloco `x-env`): `NODEBEAT_SEDE_REDES: ${NODEBEAT_SEDE_REDES:-}` e `NODEBEAT_INVENTARIO_S: ${NODEBEAT_INVENTARIO_S:-3600}`.
  - Em `.env.example`: `NODEBEAT_SEDE_REDES=<REDES_DA_SEDE_SEPARADAS_POR_VIRGULA>`.
  - No `deploy/README.md`: uma linha explicando o que são as redes da sede.

- [ ] **Step 5: Rodar a suíte toda.** `cd backend; python -m pytest -q` → tudo PASS.

- [ ] **Step 6: Commit.** `git commit -am "feat(inventario): leitura horária das MKs e gravação no Mongo"` (adicionar os arquivos novos de teste se houver).

---

### Task 3: Endpoints da API

**Files:**
- Modify: `backend/nodebeat/api.py`
- Test: `backend/tests/test_api_inventario.py` (fixtures copiadas de `test_api_mks.py`: `db`, `r`, `anon`, `client`, `criar`)

**Interfaces:**
- Consumes:
  - Task 1: `conferir_faixa`, `sobreposicoes`, `conferir_porta`, `conferir_ip`, `desatualizado`.
  - Task 2: store `*_inventario`, `listar_ips`, `esquecer_ip`, `apagar_inventario`; `worker.atualizar_mk`; `worker.PEDIDO_INVENTARIO`; `settings.sede_redes`.
- Produces: todos no router `mks` (exige login), datas em ISO 8601.

| Método e caminho | Resposta |
|---|---|
| `GET /api/faixas` | `{"mks":[{"id","nome","lido_em","erro","desatualizado","redes"}], "sede":[cidr], "sobreposicoes":[...]}`, ordenado por nome. MK sem inventário entra com `redes: []`, `lido_em: null`, `desatualizado: true` |
| `GET /api/faixas/conferir?cidr=` | `conferir_faixa(...)`; inválido → 422 `{"detail":"Faixa inválida"}` |
| `POST /api/faixas/atualizar` | 202; `r.set(PEDIDO_INVENTARIO, "1")` |
| `GET /api/mks/{id}/inventario` | `{"lido_em","erro","desatualizado","redes","pools","nat","servicos"}`; sem inventário → mesmos campos vazios, `desatualizado: true` |
| `POST /api/mks/{id}/inventario/atualizar` | roda `atualizar_mk`; sucesso → 200 com o mesmo corpo do GET; erro → 502 `{"detalhe": ...}` |
| `GET /api/mks/{id}/portas/conferir?porta=&protocolo=tcp` | `conferir_porta(...)` + `"desatualizado"`; porta fora de 1–65535 ou protocolo ≠ tcp/udp → 422 |
| `GET /api/mks/{id}/ips` | lista de `listar_ips` com `em_uso: bool` calculado (regra dos 15 dias / fixo) |
| `GET /api/mks/{id}/ips/conferir?ip=` | `conferir_ip(...)` + `"desatualizado"`; inválido → 422 `{"detail":"IP inválido"}` |
| `DELETE /api/mks/{id}/ips/{ip}` | 204, ou 404 se não existe |

- `apagar` (DELETE `/api/mks/{id}`) passa a chamar `store.apagar_inventario`.
- Todos os `/mks/{id}/...` usam `_achar` → 404 para MK inexistente.

- [ ] **Step 1: Testes que falham** em `test_api_inventario.py`:
  - `test_exige_login`: `anon.get("/api/faixas")` → 401.
  - `test_faixas_lista_e_sobreposicao`: grava inventários de duas MKs com `store.salvar_inventario` (túnel `10.30.0.0/24` nas duas) → `sobreposicoes` com 1 item; MK sem inventário aparece com `desatualizado: true`.
  - `test_conferir_faixa_invalida_422` e `test_conferir_faixa_usa_sede`: com `Settings(..., sede_redes=["10.1.0.0/16"])`, `cidr=10.1.5.0/24` → `em_uso`.
  - `test_pedido_atualizar_grava_redis`: POST → 202 e `await r.get("inventario:pedido") == "1"`.
  - `test_atualizar_mk_502_sem_vazar_senha`: monkeypatch `routeros.fetch_inventario` levantando `RouterOsError("Login recusado (usuário ou senha)")` → 502, corpo sem a senha da MK.
  - `test_conferir_porta_e_validacao`: `porta=0` → 422; `protocolo=icmp` → 422; caso válido devolve `resultado`.
  - `test_ips_em_uso_e_esquecer`: IP visto agora → `em_uso: true`; DELETE → 204; DELETE de novo → 404.
  - `test_apagar_mk_apaga_inventario`: depois de `DELETE /api/mks/{id}`, `store.get_inventario` → `None` e `listar_ips` → `[]`.

- [ ] **Step 2: Rodar e ver falhar.** `cd backend; python -m pytest tests/test_api_inventario.py -q` → FAIL.
- [ ] **Step 3: Implementar** os endpoints em `api.py`. Query params via `Query`. `atualizar_mk` é chamado com `datetime.now(UTC)`.
- [ ] **Step 4: Rodar a suíte toda.** `cd backend; python -m pytest -q` → tudo PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(api): faixas, portas e IPs das MKs com conferência"`

---

### Task 4: Front-end — tela Faixas de IP e seções Portas/IPs

**Files:**
- Modify: `frontend/lib/api/client.dart` (modelos + métodos)
- Create: `frontend/lib/screens/faixas.dart`
- Create: `frontend/lib/widgets/inventario.dart` (`PortasCard`, `IpsCard`)
- Modify: `frontend/lib/screens/mk_detail.dart` (inclui os dois cards depois das interfaces)
- Modify: `frontend/lib/screens/dashboard.dart` (ação "Faixas de IP" na AppBar → `/faixas`)
- Modify: `frontend/lib/main.dart` (rota `/faixas` em `_route`)
- Test: `frontend/test/faixas_test.dart`, `frontend/test/inventario_test.dart`

**Interfaces:**
- Consumes: endpoints da Task 3 (formatos JSON acima).
- Produces em `client.dart`:
  - Modelos `FaixasData`, `Conferencia` (campos comuns: `resultado`, `avisos`, `faltam`/`desatualizado`, mais a lista específica: `colisoes`/`usos`/`visto`), `InventarioMk`, `IpVisto`.
  - Métodos: `faixas()`, `conferirFaixa(String cidr)`, `pedirAtualizarFaixas()`, `inventario(String id)`, `atualizarInventario(String id)`, `conferirPorta(String id, int porta, String protocolo)`, `ips(String id)`, `conferirIp(String id, String ip)`, `esquecerIp(String id, String ip)`.
  - Todos via `_send`, como os atuais.

**Comportamento:**
- **Faixas:**
  - Alertas de sobreposição no topo.
  - Campo "conferir faixa" com resultado colorido.
  - Lista por condomínio: redes com selo "túnel", "lido HH:mm" e aviso `warning` quando `desatualizado` ou com `erro`.
  - Linha "Sede".
  - Botão "atualizar": faz POST e depois recarrega `faixas()` a cada 5 s até algum `lido_em` mudar ou passar 2 min.
- **PortasCard:**
  - Tabela dst-nat com porta → destino, comentário e "desativada".
  - Serviços ativos.
  - Selo `warning` "aberto para qualquer IP (sem restrição na regra)".
  - Campo porta + seletor tcp/udp → conferência.
- **IpsCard:**
  - Tabela IP, MAC, host, "visto DD/MM", selo "em uso", "fixo".
  - Botão "esquecer" com confirmação, no padrão de diálogo de `mk_detail.dart`.
  - Campo conferir IP.
- Botão "atualizar" no detalhe chama `atualizarInventario` e mostra o `detalhe` em caso de 502.
- Botões só de ícone com `tooltip`/semântica (aria-label).

- [ ] **Step 1: Testes que falham** (padrão `MockClient` de `mk_detail_test.dart`):
  - `faixas_test.dart`:
    - lista as MKs e a sede;
    - mostra o alerta de sobreposição;
    - conferir `10.30.0.0/24` mostra "em uso" e o nome do condomínio;
    - MK `desatualizado` mostra o aviso;
    - renderiza nos temas claro e escuro sem exceção.
  - `inventario_test.dart`:
    - `PortasCard` mostra `8081 → 192.168.10.20:80` e o selo de aberto;
    - conferir porta mostra "livre";
    - `IpsCard` mostra "em uso";
    - "esquecer" confirma, chama `DELETE /api/mks/x/ips/192.168.10.20` e recarrega.
- [ ] **Step 2: Rodar e ver falhar.** `cd frontend; flutter test test/faixas_test.dart test/inventario_test.dart` → FAIL.
- [ ] **Step 3: Implementar** client, tela, cards e rota, seguindo Trade UI (`TradeCard`, tokens de `TradeTokens`, `radius-pill` nos campos, `tabular-nums`/fonte mono para IPs e portas).
- [ ] **Step 4: Rodar tudo.** `cd frontend; flutter analyze; flutter test` → sem issues, tudo PASS.
- [ ] **Step 5: Conferência visual.** `flutter build web` e abrir local nos temas claro e escuro (skill `run`). Anotar no commit se ficou algo pendente.
- [ ] **Step 6: Commit.** `git commit -m "feat(frontend): tela Faixas de IP e seções Portas/IPs no detalhe da MK"`

---

### Task 5: Validação contra MKs reais (manual, com o humano)

**Files:** nenhum código novo. Corrigir no módulo que falhar, com teste que reproduz o caso (dados fictícios).

- [ ] **Step 1:** Rodar `fetch_inventario` contra uma MK v6 e uma v7 reais pela VM, numa sessão Python. Confirmar:
  - que o usuário `monitor` lê os 8 menus sem "not enough permissions";
  - os nomes reais dos campos (`dynamic`, `template`, `src-address-list`, `host-name`).
  - Não salvar a saída no repositório.
- [ ] **Step 2:** Se algum campo vier diferente, adicionar o caso como teste em `test_inventario.py` (com valores fictícios), corrigir `montar` e commitar `fix(inventario): ...`.
- [ ] **Step 3:** Deploy no CT conforme `deploy/README.md`, com `NODEBEAT_SEDE_REDES` preenchida. Conferir a tela nos dois temas e uma conferência de cada tipo.

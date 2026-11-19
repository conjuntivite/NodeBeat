# Painel de eventos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** aba "Eventos" com semáforo por MK, gráficos (pizza, barras, linha) e quatro blocos (Acesso/hacker, Autenticação, VPN, Erros) mais as 6 recomendações, sobre os eventos syslog das MKs.
**Architecture:** função pura `backend/nodebeat/painel.py` categoriza e agrega eventos já gravados; rota `GET /api/eventos/painel`; tela Flutter com gráficos `fl_chart`. Categorias calculadas na consulta (os 30 dias gravados entram).
**Tech Stack:** FastAPI/Python (pytest, mongomock_motor, fakeredis), Flutter web (flutter_test, `fl_chart`).
**Spec:** `docs/superpowers/specs/2026-11-19-painel-eventos-design.md`

## Global Constraints
- Textos da UI em pt-BR. Trade UI: só tokens semânticos (`TradeTokens`), temas claro e escuro, cor nunca é a única pista (rótulo e ícone junto), contraste ≥ 4.5:1.
- Nada de IP/domínio real no repo: testes usam `203.0.113.x`, `198.51.100.x`, `10.x`, `192.168.x`.
- Horário comercial 7 h a 19 h em UTC-3 fixo (`timezone(timedelta(hours=-3))`, sem `zoneinfo`: a imagem não tem tzdata).
- Limites como constantes no topo de `painel.py`: `SILENCIO_H=24`, `REBOOTS_24H=2`, `FLAP_N=3` (janela 1 h), `VPN_FALHAS_N=3` (janela 1 h), `PPPOE_MASSA_N=10` (janela 15 min), `INCIDENTE_MKS=3` (janela 15 min), `HABITUAL_FATOR=3`, `HABITUAL_MIN=20`, `HORA_INI=7`, `HORA_FIM=19`.
- Backend: `backend/.venv/Scripts/python -m pytest -q` (da pasta `backend`). Frontend: `flutter test` e `flutter analyze` (da pasta `frontend`).

## Review Focus
- Falha de login com **usuário vazio** (`login failure for user  from IP via telnet`, hoje `tipo=erro`) conta como acesso hacker.
- Erros PPPoE `authentication failed` (centenas, usuário `teste`) são autenticação e **não** disparam "queda em massa de PPPoE".
- MK que nunca mandou evento: amarelo ("nunca mandou eventos"), sem quebrar.
- Banco vazio, período sem eventos, `mk` filtrando: resposta completa com zeros, nunca erro 500.
- Enxurrada de falhas de ssh da internet não pode marcar "acima do habitual" (acesso externo fica fora dessa conta).
- Mensagem sem IP interpretável não vira acesso externo (cai em `erros/erro`).

---

### Task 1: categorias de evento e leitura por período
**Files:** Create `backend/nodebeat/painel.py`, `backend/tests/test_painel.py`. Modify `backend/nodebeat/store.py` (após `listar_eventos`), `backend/tests/test_store_eventos.py`.

**Interfaces:**
- Produces: `@dataclass Ctx(sede_redes: list[str], ips_sede: list[str])`; `categoria(ev: dict, ctx: Ctx) -> tuple[str, str] | None`; `falha_login(ev: dict) -> tuple[str, str, str] | None` (usuário, ip, via); constante `NORMAIS = {"login_ok", "ok"}`; `store.listar_eventos_periodo(db, desde: datetime, mk_id: str | None = None) -> list[dict]` (ordem crescente de `recebido_em`).
- `ev` é o documento do Mongo: `mk_id, recebido_em (aware), severidade, topicos, tipo, campos, mensagem`.

- [ ] **Step 1: testes que falham** em `test_painel.py` (helper `E(tipo, msg, sev="info", campos=None, topicos=())`; `CTX = Ctx(["10.1.0.0/16"], ["198.51.100.7"])`):
  - `test_falha_de_ip_publico_e_acesso`: `login_falha` "login failure for user root from 203.0.113.9 via ssh" → `("acesso","falha_externa")`.
  - `test_falha_usuario_vazio_tipo_erro_e_acesso`: `tipo="erro"`, "login failure for user  from 203.0.113.9 via telnet" → `("acesso","falha_externa")`; `falha_login` devolve `("", "203.0.113.9", "telnet")`.
  - `test_falha_de_ip_privado_ou_da_sede_e_autenticacao`: de `192.168.40.5`, de `10.1.2.3` e de `198.51.100.7` → `("autenticacao","falha_interna")`.
  - `test_login_de_fora_e_acesso_login_externo_ok`: `login` admin de `203.0.113.9` → `("acesso","login_externo_ok")`; `login` `monitor` de `203.0.113.9` e `login` admin de `192.168.1.5` → `("autenticacao","login_ok")`; `logout` → `None`.
  - `test_pppoe_authentication_failed_e_autenticacao`: `pppoe`, sev `err`, "<198.51.100.7>: user teste authentication failed" → `("autenticacao","pppoe_auth")`; "pppoe-out1: terminating..." sev `err` → `("erros","pppoe")`; pppoe info → `None`.
  - `test_ipsec`: "failed to pre-process ph2 packet." → `("vpn","falha")`; sev `err` qualquer mensagem → `("vpn","falha")`; "ISAKMP-SA established ..." e "initiate new phase 1 ..." → `("vpn","ok")`.
  - `test_erros_fisicos_e_gerais`: `outro` warning "ether3 excessive or late collision, link duplex mismatch?" → `("erros","link_fisico")`; `interface` "ether4 link down" → `("erros","interface_down")`; "ether4 link up (speed 1G, full duplex)" → `None`; `reboot` → `("erros","reboot")`; `erro` "ssl: no common ciphers" → `("erros","erro")`; `erro` "login failure for user x from lixo via ssh" → `("erros","erro")`; `outro` info, `config`, `dhcp` → `None`.
  - Em `test_store_eventos.py`: `test_listar_eventos_periodo` insere eventos de 2 MKs em horas diferentes; sem `mk_id` devolve os dois MKs desde `desde`, ordem crescente, datetimes aware; com `mk_id` só o dele.
- [ ] **Step 2:** `pytest tests/test_painel.py tests/test_store_eventos.py -q` → FAIL (módulo e função inexistentes).
- [ ] **Step 3:** implementar `painel.py` (regex relaxada `login failure for user (\S*) from ([\d.]+) via (\S+)`; IP "externo" = `ipaddress` global e fora de `ctx.ips_sede` e `ctx.sede_redes`; vpn "falha" = severidade `err` ou mensagem com `fail|error|invalid|no suitable|timed? ?out|mismatch|not found`; pppoe "authentication failed" → autenticação; `link_fisico` = mensagem com `collision` ou `duplex mismatch`) e `store.listar_eventos_periodo` (`find({"recebido_em": {"$gte": desde}, **({"mk_id": mk_id} if mk_id else {})}).sort("recebido_em", 1)` com `_utc`).
- [ ] **Step 4:** mesmos testes → PASS; suíte `pytest -q` verde.
- [ ] **Step 5:** commit `feat(painel): categoria dos eventos e leitura por período`.

### Task 2: agregação (resumo, blocos, série por hora)
**Files:** Modify `backend/nodebeat/painel.py`, `backend/tests/test_painel.py`.

**Interfaces:**
- Consumes: Task 1.
- Produces: `PERIODOS = {"24h": 24, "7d": 168, "30d": 720}`; `montar(eventos: list[dict], mks: list[dict], ctx: Ctx, agora: datetime, periodo: str, mk_id: str | None = None) -> dict`. `eventos` pode trazer 30 dias; `montar` recorta o período. `mks` são `store.list_mks` (`id`, `nome`).
- Resposta (todas as chaves sempre presentes, zeros e listas vazias quando não há dados): `periodo`, `gerado_em` (iso), `resumo{acesso,autenticacao,vpn,erros}` (exclui subtipos de `NORMAIS`), `serie_hora[{hora(iso, hora cheia), acesso, autenticacao, vpn, erros}]` (uma entrada por hora do período, inclusive zeradas), `blocos{acesso{total,top_ips[{ip,n}] (10), por_via{via:n}, por_mk[{mk_id,nome,n}], logins_externos[{mk_id,nome,usuario,ip,via,quando}]}, autenticacao{total,por_subtipo{},por_mk[]}, vpn{total,por_subtipo{},por_mk[],ultimos[{mk_id,nome,quando,mensagem}] (20 falhas mais recentes)}, erros{total,por_subtipo{},por_mk[],interfaces[{mk_id,nome,interface,n}] (link_fisico)}}`, `por_mk[{mk_id,nome,semaforo:"verde",motivos:[],contagens{categoria:n}}]` (todas as MKs, inclusive sem evento), `atencao: []`, `incidentes: []`, `config: []` (Task 3 preenche). `mk_id` filtra eventos e `por_mk`.

- [ ] **Step 1: testes que falham:** `test_resumo_conta_por_categoria` (6 eventos de tipos variados → `resumo` exato; `login_ok` e `vpn ok` não contam); `test_periodo_recorta` (evento 25 h atrás fora de `24h`, dentro de `7d`); `test_top_ips_e_por_via` (3 falhas de `203.0.113.9` ssh, 1 de `203.0.113.10` telnet → `top_ips[0]=={"ip":"203.0.113.9","n":3}`, `por_via=={"ssh":3,"telnet":1}`); `test_serie_hora_tem_todas_as_horas` (24h → 24 pontos ou 25 conforme borda: assert `len==24` e soma igual ao resumo); `test_logins_externos_lista_o_login_ok_de_fora`; `test_interfaces_link_fisico_por_interface` (`ether3` 2x, `ether4` 1x); `test_banco_vazio_devolve_estrutura_completa` (`eventos=[]`, 2 MKs → zeros, `por_mk` com 2 itens); `test_filtro_mk` (só a MK pedida em `por_mk` e nos totais); `test_periodo_invalido_levanta_ValueError`.
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** implementar `montar` (uma passada: categoriza, soma por categoria, por MK, por hora com `recebido_em.replace(minute=0, second=0, microsecond=0)`).
- [ ] **Step 4:** PASS; suíte verde.
- [ ] **Step 5:** commit `feat(painel): resumo, blocos e série por hora`.

### Task 3: semáforo, atenção, incidentes, mudanças e habitual
**Files:** Modify `backend/nodebeat/painel.py`, `backend/tests/test_painel.py`.

**Interfaces:**
- Consumes: Task 2 (`montar`, constantes). Preenche `por_mk[].semaforo/motivos`, `atencao[{mk_id,nome,semaforo,motivo}]` (MKs vermelhas primeiro, depois amarelas), `incidentes[{inicio,fim,sintoma,mks:[nome]}]`, `config[{mk_id,nome,quando,usuario,objeto,acao,fora_horario,usuario_novo}]` (eventos `config` do período, mais recentes primeiro; `usuario/objeto/acao` vêm de `campos`).
- Regras avaliadas sobre **todos os eventos recebidos** (até 30 dias), independentes do período escolhido; o recorte do período vale só para resumo, blocos, série e `config`.

- [ ] **Step 1: testes que falham** (cada um monta eventos à mão, `agora = 2026-03-05T15:00Z`):
  - `test_login_de_fora_deixa_vermelho`: motivo contém `"Login de fora"`.
  - `test_dois_reboots_em_24h_vermelho`; um reboot → verde.
  - `test_oscilacao_de_interface`: 3 `interface down` da `ether3` em 40 min → vermelho, motivo contém `"ether3"`; 2 downs → verde; 3 downs em 3 h → verde.
  - `test_falhas_de_vpn_em_1h_vermelho` (3 `ipsec` falha em 1 h).
  - `test_queda_em_massa_pppoe`: 10 `pppoe` err (não `authentication failed`) em 15 min → vermelho. **Review Focus:** 30 `pppoe` "authentication failed" em 15 min → verde.
  - `test_silencio_amarelo`: MK cuja última mensagem tem 25 h → amarelo `"Sem eventos há mais de 24 h"`; MK sem nenhum evento → amarelo `"Nunca mandou eventos"`; MK com evento há 23 h → verde.
  - `test_acima_do_habitual`: 7 dias anteriores com 35 eventos de erro (média 5/dia) e 20 nas últimas 24 h → amarelo `"Acima do habitual"`; 19 → verde. **Review Focus:** 200 falhas de ssh externas nas últimas 24 h e média baixa → verde.
  - `test_incidente_correlacionado`: `interface down` em 3 MKs diferentes em 10 min → 1 incidente (`sintoma "interface_down"`, `mks` com 3 nomes); em 2 MKs → nenhum; 3 eventos da mesma MK → nenhum.
  - `test_config_fora_do_horario`: config às `2026-03-05T01:00Z` (22 h em UTC-3) → `fora_horario=True`; às `15:00Z` → `False`.
  - `test_usuario_novo`: MK com config de `admin` há 5 dias; config de `fulano` nas últimas 24 h → `usuario_novo=True` e MK amarela `"Usuário novo"`; `admin` → `False`. MK sem histórico anterior de usuário não marca novo.
  - `test_atencao_ordena_vermelho_primeiro` e `test_filtro_mk_mantem_incidente_da_mk` (incidente de 3 MKs aparece ao filtrar uma delas, some ao filtrar outra fora dele).
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** implementar. Contas "importantes" do habitual: categorias `vpn`, `erros` e `autenticacao` excluindo `NORMAIS`; **acesso externo fora**. "Usuário novo": usuário que aparece em evento `config/login/logout` da MK só nas últimas 24 h, e a MK tem ao menos um evento com usuário mais antigo que 24 h. `fora_horario`: hora em UTC-3 `< HORA_INI` ou `>= HORA_FIM`.
- [ ] **Step 4:** PASS; suíte verde.
- [ ] **Step 5:** commit `feat(painel): semáforo, incidentes, mudanças e comparação com o habitual`.

### Task 4: rota `GET /api/eventos/painel`
**Files:** Modify `backend/nodebeat/api.py` (junto de `eventos_mk`), Create `backend/tests/test_api_painel.py` (mesmas fixtures de `test_api_eventos.py`; `SET` com `sede_redes=["10.1.0.0/16"]` e `ips_publicos_sede=["198.51.100.7"]`).

**Interfaces:**
- Consumes: `painel.montar`, `painel.Ctx`, `painel.PERIODOS`, `store.listar_eventos_periodo`, `store.list_mks`, `settings.sede_redes`, `settings.ips_publicos_sede`.
- Produces: `GET /api/eventos/painel?periodo=24h|7d|30d&mk=<id>` → 200 com o corpo de `montar`; `periodo` padrão `24h`.

- [ ] **Step 1: testes que falham:** `test_exige_login` (401 sem cookie); `test_periodo_invalido_422`; `test_mk_inexistente_404`; `test_painel_vazio_200_com_estrutura` (sem eventos: `resumo` com 4 zeros, `por_mk` com as MKs criadas); `test_classifica_com_sede_do_settings` (falha de `203.0.113.9` conta em `acesso`, de `198.51.100.7` em `autenticacao`); `test_filtro_mk` (query `mk=<id>` devolve só ela em `por_mk`).
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** implementar a rota: `periodo: str = Query("24h", pattern="^(24h|7d|30d)$")`, `mk: str | None = None` (se vier, `await _achar(mk)`); lê `agora - 30 dias`, `list_mks`, chama `montar`. Teto registrado com `# ponytail:` (lê até 30 dias de eventos em memória; mover para pipeline do Mongo se passar de dezenas de milhares).
- [ ] **Step 4:** PASS; `pytest -q` verde.
- [ ] **Step 5:** commit `feat(painel): rota /api/eventos/painel`.

### Task 5: cliente da API, modelos e gráficos no Flutter
**Files:** Modify `frontend/pubspec.yaml` (via `flutter pub add fl_chart`), `frontend/lib/api/client.dart`. Create `frontend/lib/widgets/graficos.dart`, `frontend/test/painel_api_test.dart`, `frontend/test/graficos_test.dart`.

**Interfaces:**
- Produces em `client.dart`: `class PainelEventos` com `fromJson` espelhando a resposta da Task 2/3 (campos: `periodo`, `resumo` `Map<String,int>`, `serieHora` `List<PontoSerie>{hora, valores Map<String,int>}`, `blocos` `Map<String, BlocoPainel>`, `porMk` `List<MkPainel>{mkId, nome, semaforo, motivos, contagens}`, `atencao`, `incidentes`, `config`); `ApiClient.painelEventos(String periodo, {String? mkId}) -> Future<PainelEventos>` (GET `/eventos/painel?periodo=..&mk=..`).
- Produces em `graficos.dart`: `GraficoPizza({required Map<String,int> dados})`, `GraficoBarras({required List<(String,int)> dados})`, `GraficoLinha({required List<PontoSerie> pontos, required List<String> series})`. Cores por categoria vêm de `TradeTokens` (acesso→`negative`, autenticacao→`info`, vpn→`risk`, erros→`warning`), sempre com legenda textual com o número.

- [ ] **Step 1: testes que falham:** `painel_api_test.dart`: `fromJson` de um JSON de exemplo completo lê `resumo['acesso']`, `porMk.first.semaforo`, `blocos['acesso'].topIps.first`; `painelEventos('7d', mkId: 'x')` chama `/api/eventos/painel?periodo=7d&mk=x` (MockClient). `graficos_test.dart`: cada gráfico, em tema claro e escuro, mostra a legenda com rótulo e número (`find.text('acesso: 12')` ou equivalente) e, sem dados (mapa/lista vazios), mostra `Sem eventos no período`.
- [ ] **Step 2:** `flutter test` nos dois arquivos → FAIL.
- [ ] **Step 3:** `flutter pub add fl_chart` (registrar a versão no ledger; se conflitar com `material_ui`, rule e registre). Implementar modelos, método e os três widgets.
- [ ] **Step 4:** `flutter test` verde, `flutter analyze` limpo.
- [ ] **Step 5:** commit `feat(painel): cliente da API e gráficos fl_chart`.

### Task 6: tela, rota e botão
**Files:** Create `frontend/lib/screens/painel_eventos.dart`, `frontend/test/painel_eventos_test.dart`. Modify `frontend/lib/main.dart` (`['eventos'] => PainelEventosScreen(api: api)`), `frontend/lib/screens/dashboard.dart` (botão ao lado de "Preparar MK": tooltip `Eventos`, `Icons.insights_outlined`, `pushNamed('/eventos')`), `frontend/test/dashboard_test.dart` (existência do botão).

**Interfaces:**
- Consumes: `PainelEventos`, `ApiClient.painelEventos`, `Grafico*`.
- Produces: `PainelEventosScreen({required ApiClient api})`.

Layout: AppBar "Eventos" + seletor de período (`SegmentedButton` 24 h / 7 dias / 30 dias) + filtro de MK (`DropdownButton`, "Todas as MKs"). Corpo: faixa "Atenção agora" (cada item com ícone e texto do semáforo, toque abre `/mk/<id>`; "Tudo certo" quando vazia), incidentes, linha do resumo (pizza, barras por MK, linha por hora), quatro cartões (Acesso/hacker com top IPs e serviços e logins de fora; Autenticação; VPN; Erros importantes com interfaces de colisão), mudanças de configuração com selos "fora do horário" e "usuário novo". Estados: carregando, erro com "Tentar de novo".

- [ ] **Step 1: testes que falham** (`painel_eventos_test.dart`, MockClient com resposta de exemplo; tema claro e escuro): mostra "Atenção agora" com o nome da MK vermelha e o motivo; mostra os quatro cartões com seus totais; trocar para "7 dias" refaz a requisição com `periodo=7d`; escolher uma MK refaz com `mk=<id>`; tocar numa MK da faixa navega para `/mk/<id>`; resposta com zeros mostra "Tudo certo" e "Sem eventos no período"; falha da API mostra erro e "Tentar de novo". `dashboard_test.dart`: existe o botão `Eventos`.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** implementar a tela, a rota e o botão.
- [ ] **Step 4:** `flutter test` (suíte inteira) verde; `flutter analyze` limpo.
- [ ] **Step 5:** commit `feat(painel): aba Eventos com semáforo, gráficos e blocos`.

### Task 7: deploy no CT 119 e conferência com dados reais
**Files:** `docs/andamento.local.md` (gitignored); sem código novo.

- [ ] **Step 1:** merge na `main` só depois da revisão final e do OK do usuário. Deploy: `git archive HEAD | ssh root@192.168.60.200 "pct exec 119 -- tar -x -C /opt/nodebeat"` e `docker compose -f deploy/compose.yml --env-file deploy/.env up -d --build api web` dentro do CT.
- [ ] **Step 2:** com `curl`/script no container `api`, chamar `/api/eventos/painel?periodo=30d` e conferir: `resumo.acesso` próximo de 2000, ≥ 1 MK com `link_fisico`, as 19 MKs em `por_mk`, nenhum 500.
- [ ] **Step 3:** abrir a aba no navegador (tema claro e escuro) e conferir gráficos e semáforo; mostrar ao usuário.
- [ ] **Step 4:** atualizar `docs/andamento.local.md` (aba pronta, eventos ligados nas 19 MKs, COSMOPOLITANO sem acesso) e a memória.

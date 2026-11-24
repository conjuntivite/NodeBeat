# Equipamentos por tipo e Switch: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** abas MK | Switch | Firewall no painel, o Switch monitorado como equipamento próprio (descoberto ou manual) e o desenho frontal das portas, estilo UniFi, no switch e na MK.

**Architecture:** coleção nova `equipamentos` ao lado de `mks`, que não muda. O worker sincroniza os switches gerenciáveis descobertos em `equipamentos` e, a cada `mapa_s` (60 s), pinga cada equipamento e lê as portas por SNMP. O estado vai para `state:eq:<id>` e passa pelo mesmo `AlertEngine`, com chaves `eq:<id>|…`. Um módulo puro, `portas.py`, guarda o histórico de link por porta (com/sem link/caiu) para a MK e para o switch. No Flutter, um widget único de desenho serve às duas telas.

**Tech Stack:** Python 3.14, FastAPI, motor/Mongo, redis.asyncio, SNMP próprio (`snmp.py`), Flutter web (`material_ui`, tokens `tokens.g.dart`). Testes: pytest + mongomock_motor + fakeredis; flutter_test + MockClient.

**Spec:** `docs/superpowers/specs/2026-11-24-equipamentos-switch-design.md`

## Global Constraints

- A coleção `mks` e o fluxo das MKs (`run_cycle`, `_check`, `observe_mk`) não mudam de comportamento. O único acréscimo é o campo `portas` no estado.
- A community SNMP é segredo: nunca em log, em mensagem de erro, em resposta da API ou em texto puro no banco. Usar `crypto.encrypt/decrypt` com `settings.secret_key`.
- Webhook: `mk` continua `{id, nome}`. Para a sede, `{"id": "sede", "nome": "Sede"}`, nunca `null`. O campo novo é `equipamento: {id, nome, tipo}`. O `detalhe` começa pelo nome do equipamento.
- Webhook só para `queda`, e nunca para `erro_acesso`, como já é hoje em `_emit`.
- Sem ticket em cascata: não observar o equipamento no motor enquanto a MK do local não está `no_ar` ou o switch pai está fora.
- Porta de uplink: porta com switch gerenciável filho ou com `UPLINK_MIN_VIGIADOS = 3` ou mais aparelhos vigiados ligados nela. Ticket `uplink_caido` só na porta com 3 ou mais vigiados e **sem** switch gerenciável filho. Se houver filho, o `offline` dele cobre.
- Porta comum que caiu fica `caiu` por `CAIU_JANELA_S = 86400` e depois vira `sem link`.
- Cores só pelos tokens: com link = `positiveFill`, sem link = cinza neutro do tema (`borderSubtle`/`fgMuted`), caiu = `negativeFill`. Os temas claro e escuro são obrigatórios.
- Nunca commitar IPs reais, domínio ou communities; nos testes, usar 192.0.2.x/198.51.100.x/10.x.
- TDD em cada tarefa. Backend: `.venv/Scripts/python -m pytest -q` (a partir de `backend/`). Front: `flutter test` e `flutter analyze` limpos (a partir de `frontend/`).
- Commits com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. `run_cycle` chama `engine.forget_mk(id)` para todo `mk_ids()` que não é MK. As chaves `eq:<id>|…` não podem sumir a cada ciclo (teste na Task 3).
2. Um engine salvo no Redis antes do deploy (trackers sem o campo `eq`) precisa carregar sem erro (teste na Task 3).
3. Eventos de syslog de switch (`mk_id = "eq:<id>"`) não podem quebrar nem contaminar o painel de eventos das MKs (teste na Task 7).
4. Switch descoberto que deixou de ser gerenciável, ou switch manual apagado: o `state:eq:<id>` e os trackers somem, sem ticket fantasma (teste na Task 6).
5. A MK tem dezenas de interfaces (bridge, vlan, pppoe, wireguard, ipsec, lo): o desenho mostra só as portas físicas (teste na Task 1).

---

### Task 1: `portas.py`, o histórico de link por porta e o filtro de porta física

**Files:**
- Create: `backend/nodebeat/portas.py`
- Test: `backend/tests/test_portas.py`

**Interfaces:**
- Produces:
  - `CAIU_JANELA_S = 86400`
  - `fisica_mk(nome: str) -> bool`: True para nomes que começam com `ether`, `sfp`, `combo`, `qsfp`, case-insensitive; False para o resto (bridge, vlan…, pppoe…, wg…, lo, ipsec…).
  - `atualizar(ant: dict[str, dict] | None, up: dict[str, bool], agora: datetime) -> dict[str, dict]`: cada porta de `up` vira `{"up": bool, "desde": iso, "caiu_em": iso | None, "velocidade": <mantida>}`. O `desde` muda quando o `up` muda. O `caiu_em` recebe `agora` na passagem de True para False, é mantido enquanto a porta segue False e volta a None quando ela volta a True. Porta ausente em `up` sai do resultado.
  - `estado_porta(p: dict, agora: datetime) -> str`: `"up"` | `"caiu"` (False e `caiu_em` a menos de `CAIU_JANELA_S`) | `"down"`.

- [ ] **Step 1: Write the failing tests**

```python
T = datetime(2026, 1, 1, 12, tzinfo=UTC)

def test_fisica_mk():
    assert all(fisica_mk(n) for n in ["ether1", "sfp-sfpplus1", "combo1", "SFP1", "qsfp28-1-1"])
    assert not any(fisica_mk(n) for n in ["bridge", "vlan10", "pppoe-out1", "wg0", "lo", "ipsec-x", "ovpn-in"])

def test_atualizar_marca_caiu_so_na_queda():
    a = atualizar(None, {"ether1": True, "ether2": False}, T)
    assert a["ether1"]["caiu_em"] is None and a["ether2"]["caiu_em"] is None  # nunca teve link: não "caiu"
    b = atualizar(a, {"ether1": False, "ether2": False}, T + timedelta(minutes=1))
    assert b["ether1"]["caiu_em"] == (T + timedelta(minutes=1)).isoformat()
    assert b["ether1"]["desde"] == (T + timedelta(minutes=1)).isoformat()
    c = atualizar(b, {"ether1": False}, T + timedelta(minutes=2))
    assert c["ether1"]["caiu_em"] == b["ether1"]["caiu_em"] and "ether2" not in c
    assert atualizar(c, {"ether1": True}, T + timedelta(minutes=3))["ether1"]["caiu_em"] is None

def test_estado_porta_caiu_vira_down_depois_de_24h():
    p = {"up": False, "caiu_em": T.isoformat()}
    assert estado_porta(p, T + timedelta(hours=23)) == "caiu"
    assert estado_porta(p, T + timedelta(hours=24, seconds=1)) == "down"
    assert estado_porta({"up": True, "caiu_em": None}, T) == "up"
    assert estado_porta({"up": False, "caiu_em": None}, T) == "down"
```

- [ ] **Step 2: Run** `.venv/Scripts/python -m pytest tests/test_portas.py -q`. Expected: FAIL (o módulo não existe).
- [ ] **Step 3: Implement** as três funções em `backend/nodebeat/portas.py` (stdlib apenas).
- [ ] **Step 4: Run** de novo. Expected: PASS.
- [ ] **Step 5: Commit** `feat(portas): histórico de link por porta e filtro de porta física`

### Task 2: o estado da MK ganha `portas` e o desenho da MK recebe dado

**Files:**
- Modify: `backend/nodebeat/worker.py` (`_check`, no `save_state`)
- Test: `backend/tests/test_worker.py`

**Interfaces:**
- Consumes: `portas.atualizar`, `portas.fisica_mk`.
- Produces: o `state:mk:<id>` ganha `"portas": {nome: {"up", "desde", "caiu_em"}}`, só com as portas físicas. MK fora do ar mantém as `portas` anteriores, porque sem leitura não se sabe o link. O `GET /api/mks/{id}` já devolve `estado` inteiro, sem mudança na API.

- [ ] **Step 1: Write the failing test** `test_estado_da_mk_guarda_portas_fisicas_e_caiu`. Um `fetch` devolve `Snapshot(..., {"ether1": True, "ether2": True, "bridge": True})`. Depois de um ciclo, `states[id]["portas"]` tem as chaves `{"ether1", "ether2"}`. No ciclo seguinte, com `ether2: False`, o `portas["ether2"]["caiu_em"]` é o `now` do 2º ciclo. Num 3º ciclo com `fetch_fail`, as `portas` continuam iguais às do 2º.
- [ ] **Step 2: Run** `.venv/Scripts/python -m pytest tests/test_worker.py -k portas -q`. Expected: FAIL (`KeyError: 'portas'`).
- [ ] **Step 3: Implement** em `_check`: `portas = portas.atualizar(ant.get("portas") if ant else None, {n: v for n, v in snap.ifaces.items() if portas.fisica_mk(n)}, now) if ok else (ant or {}).get("portas", {})`. Gravar no `save_state`. Usar o import `from . import portas as portas_mod` para não sombrear.
- [ ] **Step 4: Run** a suíte inteira do backend. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): estado da MK guarda o link de cada porta física`

### Task 3: o motor de alertas aceita equipamento

**Files:**
- Modify: `backend/nodebeat/rules.py`, `backend/nodebeat/history.py` (`record`)
- Test: `backend/tests/test_rules.py`, `backend/tests/test_history.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) class EqRef: id: str; nome: str; tipo: str`
  - `Event` ganha o último campo `equipamento: EqRef | None = None`. O `to_payload()` acrescenta `"equipamento": {"id", "nome", "tipo"} | None`.
  - `_Tracker` ganha `eq: EqRef | None = None`. `dump()` grava `"eq"` e `load()` usa `t.get("eq")`: engine antigo sem a chave carrega.
  - `@dataclass(frozen=True) class EqObs: estado: str; detalhe: str = ""; uplinks_caidos: dict[str, str] = field(default_factory=dict)`. O `estado` é `"no_ar"` | `"offline"` | `"erro_acesso"`, e `uplinks_caidos` vai de porta para detalhe.
  - `AlertEngine.observe_equipamento(self, eq: EqRef, local: MkRef, obs: EqObs, now: datetime, *, acima_fora: bool) -> list[Event]`:
    - congelado → `[]`;
    - `acima_fora` → apaga os trackers `pending` com prefixo `eq:<id>|` e devolve `[]`, mantendo os que estão `alerting`;
    - senão, a chave `eq:<id>|eq` com `bad = obs.estado != "no_ar"` e `tipo = obs.estado`. Com o equipamento fora e a queda confirmada, fecha as paralelas (`encerrado`), como na MK;
    - no ar: uma chave `eq:<id>|uplink:<porta>` por item de `uplinks_caidos`, com tipo `uplink_caido`. As chaves de uplink que não vieram são descartadas sem evento.
    - Os eventos saem com `mk=local` e `equipamento=eq`, e o detalhe começa por `f"{eq.nome}: "`.
  - `AlertEngine.forget_eq(eq_id: str) -> None` e `eq_ids() -> set[str]`.
  - `mk_ids()` passa a ignorar as chaves que começam com `eq:`.
  - `history.record`: com `ev.equipamento`, a chave é `hist:eq:<id>`; senão, segue como hoje.

- [ ] **Step 1: Write the failing tests** em `test_rules.py`:

```python
EQ = EqRef("e1", "USW Sede", "switch"); SEDE = MkRef("sede", "Sede")

def test_switch_offline_confirma_e_payload_tem_equipamento():
    e = AlertEngine()
    assert e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0, acima_fora=False) == []
    [ev] = e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0 + timedelta(seconds=120), acima_fora=False)
    p = ev.to_payload()
    assert p["evento"] == "queda" and p["tipo"] == "offline"
    assert p["mk"] == {"id": "sede", "nome": "Sede"}
    assert p["equipamento"] == {"id": "e1", "nome": "USW Sede", "tipo": "switch"}
    assert p["detalhe"].startswith("USW Sede")

def test_acima_fora_nao_alerta_e_zera_pendente():
    e = AlertEngine()
    e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0, acima_fora=False)
    assert e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0 + timedelta(seconds=200), acima_fora=True) == []
    assert e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0 + timedelta(seconds=210), acima_fora=False) == []  # recomeça

def test_uplink_caido_so_com_equipamento_no_ar():
    e = AlertEngine()
    o = EqObs("no_ar", uplinks_caidos={"0/12": "porta 0/12 sem link (4 aparelhos)"})
    e.observe_equipamento(EQ, SEDE, o, T0, acima_fora=False)
    [ev] = e.observe_equipamento(EQ, SEDE, o, T0 + timedelta(seconds=120), acima_fora=False)
    assert ev.tipo == "uplink_caido"

def test_mk_ids_ignora_equipamentos():
    e = AlertEngine(); e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0, acima_fora=False)
    assert e.mk_ids() == set() and e.eq_ids() == {"e1"}

def test_load_de_engine_antigo_sem_eq():
    d = AlertEngine().dump()
    d["trackers"] = {"m1|mk": {"phase": "pending", "tipo": "offline", "detalhe": "", "primeiro": T0.isoformat(),
                               "voltou": None, "mk": {"id": "m1", "nome": "x"}}}
    assert AlertEngine.load(d).mk_ids() == {"m1"}
```

E em `test_history.py`, `test_record_de_equipamento_vai_para_hist_eq`, que confere que o evento com `equipamento=EQ` cai em `hist:eq:e1`.

- [ ] **Step 2: Run** `.venv/Scripts/python -m pytest tests/test_rules.py tests/test_history.py -q`. Expected: FAIL (`ImportError: EqRef`).
- [ ] **Step 3: Implement** conforme as Interfaces. O `_step` ganha o parâmetro `eq: EqRef | None = None`, passado ao `_Tracker` e ao `Event`.
- [ ] **Step 4: Run** a suíte inteira. Expected: PASS. Nenhum teste de MK muda.
- [ ] **Step 5: Commit** `feat(rules): motor de alertas aceita equipamento (chaves eq:, payload com equipamento)`

### Task 4: o store e o estado de `equipamentos`

**Files:**
- Modify: `backend/nodebeat/store.py`, `backend/nodebeat/history.py`
- Test: `backend/tests/test_store_equipamentos.py`

**Interfaces:**
- Produces (store):
  - `listar_equipamentos(db, tipo: str | None = None) -> list[dict]` (com `id`)
  - `get_equipamento(db, id: str) -> dict | None`
  - `inserir_equipamento(db, doc: dict) -> str`: grava `criado_em`
  - `atualizar_equipamento(db, id: str, campos: dict) -> bool`
  - `apagar_equipamento(db, id: str) -> bool`
  - `upsert_descoberto(db, tipo: str, mk_id: str, ip: str, nome: str) -> str`: a chave única é (`tipo`, `local=mk_id`, `ip`, `origem="descoberto"`). O `nome` só entra no insert (`$setOnInsert`), para não sobrescrever um nome editado.
  - O documento: `{tipo, nome, ip, local: mk_id | "sede", origem: "manual" | "descoberto", community_cifrada?: str, criado_em}`
- Produces (history): `save_eq_state(r, id, row)`, `load_eq_states(r) -> dict[str, dict]` (`state:eq:*`), `delete_eq(r, id)` (apaga `state:eq:<id>` e `hist:eq:<id>`).

- [ ] **Step 1: Write the failing tests**:
  - `test_upsert_descoberto_e_idempotente_e_preserva_nome`: chamar duas vezes devolve o mesmo id; depois de `atualizar_equipamento(nome="Garagem")`, um novo upsert com outro nome mantém "Garagem".
  - `test_listar_por_tipo`.
  - `test_estado_eq_salva_carrega_apaga` (fakeredis).
- [ ] **Step 2: Run** `.venv/Scripts/python -m pytest tests/test_store_equipamentos.py -q`. Expected: FAIL.
- [ ] **Step 3: Implement** seguindo o padrão de `_oid/_out` do `store.py`, com um índice único em `(tipo, local, ip, origem)` criado no upsert.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(store): coleção equipamentos e estado state:eq`

### Task 5: leitura leve das portas por SNMP e cálculo dos uplinks

**Files:**
- Modify: `backend/nodebeat/switches.py`
- Test: `backend/tests/test_switches.py`

**Interfaces:**
- Produces:
  - `IFHIGHSPEED = "1.3.6.1.2.1.31.1.1.1.15"`
  - `async ler_portas(ip: str, community: str, *, walk=snmp.walk) -> dict[str, dict]`: faz walk em `BASE_IFINDEX`, `IFNAME`, `IFOPER` e `IFHIGHSPEED`, e devolve `{nome: {"up": bool, "velocidade": int | None}}` (Mbps) só para os ifIndex da bridge, como no `ler_switch`. Deixa o `SnmpErro` propagar.
  - `UPLINK_MIN_VIGIADOS = 3`
  - `uplinks(switch_ip: str, ips: list[dict]) -> dict[str, dict]`: a partir dos documentos de `inventario_ips` da MK (campos `switch_ip`, `switch_porta`, `gerenciavel`, mais o `mapa.vigiado`), devolve `{porta: {"filho": ip | None, "vigiados": int}}` para as portas com switch gerenciável filho ou com `vigiados >= UPLINK_MIN_VIGIADOS`. As ligações gravadas persistem depois da queda do link, e por isso o cálculo continua valendo com a porta caída.

- [ ] **Step 1: Write the failing tests**:
  - `test_ler_portas_com_velocidade`: walk falso a partir das amostras saneadas de `tests/amostras_snmp.txt`, ou dados à mão; a porta `0/1` up a 1000, a `0/2` down.
  - `test_uplinks_filho_e_switch_burro`:

```python
ips = [{"ip": "10.0.0.20", "switch_ip": "10.0.0.2", "switch_porta": "0/5", "gerenciavel": True},
       *[{"ip": f"10.0.0.{i}", "switch_ip": "10.0.0.2", "switch_porta": "0/12", "fabricante": "Hikvision"} for i in (31, 32, 33)],
       *[{"ip": f"10.0.0.{i}", "switch_ip": "10.0.0.2", "switch_porta": "0/13", "fabricante": "Hikvision"} for i in (41, 42)],
       {"ip": "10.0.0.50", "switch_ip": "10.0.0.9", "switch_porta": "0/1", "fabricante": "Hikvision"}]
assert uplinks("10.0.0.2", ips) == {"0/5": {"filho": "10.0.0.20", "vigiados": 1},
                                    "0/12": {"filho": None, "vigiados": 3}}
```

- [ ] **Step 2: Run** `.venv/Scripts/python -m pytest tests/test_switches.py -q`. Expected: FAIL.
- [ ] **Step 3: Implement.** Em `vigiados`, o switch filho gerenciável também conta (o `mapa.vigiado` já o considera vigiado).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(switches): leitura leve das portas e uplinks (filho e switch burro)`

### Task 6: o worker monitora os equipamentos

**Files:**
- Modify: `backend/nodebeat/worker.py`
- Test: `backend/tests/test_worker_equipamentos.py`

**Interfaces:**
- Consumes: Tasks 1, 3, 4 e 5; `probes.ping`; `crypto`; `store.listar_switches/listar_ips`; `history.load_states`.
- Produces:
  - `async sincronizar_descobertos(db, r, engine) -> None`, chamada no fim de `run_switches`:
    - todo doc de `db.switches` com `gerenciavel=True` ganha um `upsert_descoberto("switch", mk_id, ip, nome)`, com o nome vindo do `descr` cortado em 40 caracteres ou, sem ele, do IP;
    - todo equipamento `descoberto` sem doc gerenciável correspondente é apagado: `apagar_equipamento`, `history.delete_eq` e `engine.forget_eq`.
    - A community do descoberto fica no `db.switches.community_cifrada`, que já existe. Não copiar.
  - `async run_equipamentos(db, r, engine, settings, now, *, ping=probes.ping, ler_portas=switches.ler_portas) -> None`, que nunca levanta. Para cada equipamento `tipo="switch"`, com `Semaphore(10)`:
    1. ping. Sem resposta conta uma `falha` no estado; com 2 falhas seguidas, o estado vira `offline` (como em `mapa.proximo_estado`);
    2. com ping ok, `ler_portas` com a community: a do manual vem de `community_cifrada` do equipamento, a do descoberto vem de `db.switches`. Leitura boa dá `no_ar`; `SnmpErro` dá `erro_acesso` com o detalhe `"Responde ping, mas não o SNMP"`;
    3. `portas = portas.atualizar(ant_portas, {n: p["up"] for n, p in lidas.items()}, now)`, com a velocidade copiada para dentro;
    4. `ups = switches.uplinks(ip, ips_da_mk)` para o descoberto (o manual da sede fica com `{}`). `uplinks_caidos` são as portas de `ups` com `filho is None` e com a porta `up=False`;
    5. `acima_fora`: o local é MK e `state:mk:<local>.status != "no_ar"`, ou o switch pai (o `switch_ip` do doc de `inventario_ips` deste IP, procurado em `equipamentos` pelo `(local, ip)`) tem o `state:eq` com status diferente de `no_ar`;
    6. `local_ref = MkRef(mk_id, nome da MK)` ou `MkRef("sede", "Sede")`;
    7. emite `engine.observe_equipamento(...)` por `_emit`;
    8. grava `save_eq_state(r, id, {"status", "detalhe", "desde", "falhas", "portas", "uplinks": ups, "atualizado_em"})`, com o `desde` seguindo a mesma regra do `_check`.
  - `main()`: no mesmo ponto em que o `run_mapa` é agendado, `await run_equipamentos(...)` **inline**, sem task, para não mexer no engine em paralelo com o `run_cycle`. Use `asyncio.timeout(settings.mapa_s)` e grave o engine (`r.set("engine", …)`) logo depois.
  - Os equipamentos inexistentes saem do engine: `engine.eq_ids() - ids_atuais` → `forget_eq`.

- [ ] **Step 1: Write the failing tests** (ping, ler_portas e fakeredis/mongomock falsos):
  - `test_manual_offline_abre_ticket_depois_de_2_falhas_e_confirmacao`: switch manual na sede com o ping sempre falso. Com ciclos de 0, 60, 120 e 180 s, a `QUEUE` tem 1 item, com `equipamento.tipo == "switch"` e `mk.id == "sede"`.
  - `test_erro_acesso_sem_ticket`: ping ok e `ler_portas` levantando `SnmpErro`. O status fica `erro_acesso` e a `QUEUE` fica vazia.
  - `test_cascata_mk_fora_nao_abre_ticket`: descoberto na MK `m` com `state:mk:m` em `offline` e o ping falso por 5 ciclos. A `QUEUE` fica vazia e o `state:eq` fica `offline`.
  - `test_uplink_switch_burro_abre_ticket_e_filho_gerenciavel_nao`: porta `0/12` com 3 vigiados cai, gerando 1 ticket `uplink_caido`; porta `0/5` com filho gerenciável cai, sem ticket de uplink.
  - `test_descoberto_que_deixa_de_ser_gerenciavel_some`: depois de `sincronizar_descobertos`, o equipamento, o `state:eq` e os trackers somem.
  - `test_community_nunca_no_log` (`caplog`): o `ler_portas` levanta `Exception("public")` e "public" não aparece em `caplog.text`.
- [ ] **Step 2: Run** `.venv/Scripts/python -m pytest tests/test_worker_equipamentos.py -q`. Expected: FAIL.
- [ ] **Step 3: Implement** conforme as Interfaces. Logar só `type(e).__name__`.
- [ ] **Step 4: Run** a suíte inteira. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): monitora equipamentos (ping, portas, uplink, sem cascata)`

### Task 7: o syslog associa o equipamento pelo IP

**Files:**
- Modify: `backend/nodebeat/syslog.py` (`mapa_ips`)
- Test: `backend/tests/test_syslog.py`, `backend/tests/test_painel.py`

**Interfaces:**
- Produces: `mapa_ips` inclui `eq["ip"] -> f"eq:{eq['id']}"` para cada equipamento. Um IP repetido com uma MK ou com outro equipamento vira `None` (ambíguo), como hoje. O evento é gravado com `mk_id = "eq:<id>"`, sem campo novo. O `store.listar_eventos(db, "eq:<id>")` já serve.

- [ ] **Step 1: Write the failing tests**:
  - `test_mapa_ips_inclui_equipamentos`.
  - `test_painel_ignora_eventos_de_equipamento`, em `test_painel.py`: um evento `mk_id="eq:x"` no período não aparece em nenhuma lista e não levanta `KeyError`.
- [ ] **Step 2: Run.** Expected: FAIL o primeiro; o segundo pode já passar (linha 136 do `painel.py`). Se passar, fica como trava.
- [ ] **Step 3: Implement** em `mapa_ips`. Se o teste do painel falhar, filtrar `e["mk_id"] in nomes` antes de contar.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(syslog): eventos de equipamento pelo IP de origem`

### Task 8: a API de equipamentos

**Files:**
- Modify: `backend/nodebeat/api.py` (um `APIRouter` com o mesmo `Depends(auth.current_user)`)
- Test: `backend/tests/test_api_equipamentos.py` (fixtures de `tests/test_api_inventario.py`)

**Interfaces:**
- Produces:
  - `GET /api/equipamentos?tipo=switch` → `[{"id", "tipo", "nome", "ip", "local", "local_nome", "origem", "estado": state:eq | null, "portas_total", "portas_up"}]`, ordenado por local (Sede primeiro) e nome.
  - `POST /api/equipamentos` `{tipo: "switch", nome, ip, local: "sede" | mk_id, community?: str}`:
    - devolve 201 `{id}`;
    - 422 se o `tipo` não estiver em `TIPOS = {"switch"}`, se o IP for inválido ou se o `local` não existir;
    - 409 se já houver um equipamento com o mesmo (`local`, `ip`);
    - community ausente usa `settings.snmp_communities[0]`; é gravada sempre cifrada.
  - `GET /api/equipamentos/{id}` → o mesmo formato de linha, mais `uplinks`. **Nunca** devolve `community` nem `community_cifrada`.
  - `PUT /api/equipamentos/{id}` `{nome?, ip?, community?}`: o descoberto só aceita `nome` (422 para o resto).
  - `DELETE /api/equipamentos/{id}`: 204 para o manual; 409 para o descoberto, com a mensagem "Switch descoberto some sozinho quando deixa de responder SNMP". Ao apagar, roda `history.delete_eq`.
  - `GET /api/equipamentos/{id}/eventos` → `store.listar_eventos(db, f"eq:{id}", limite=200)`.
  - `GET /api/equipamentos/{id}/historico` → `history.history(r, f"eq:{id}")`.

- [ ] **Step 1: Write the failing tests**: exige login (401); criar manual na sede com a community padrão; o GET não contém `"community"` em nenhuma chave (`assert "community" not in json.dumps(body)`); 409 para (local, ip) repetido; 409 ao apagar um descoberto; 422 para tipo desconhecido; a lista vem com o estado do `state:eq`.
- [ ] **Step 2: Run.** Expected: FAIL (404).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** a suíte inteira. Expected: PASS.
- [ ] **Step 5: Commit** `feat(api): equipamentos (lista, cadastro manual, detalhe, eventos)`

### Task 9: Flutter, os modelos e o widget de desenho das portas

**Files:**
- Modify: `frontend/lib/api/client.dart`
- Create: `frontend/lib/widgets/painel_portas.dart`
- Test: `frontend/test/painel_portas_test.dart`

**Interfaces:**
- Produces:
  - `class PortaVista { final String nome; final String estado; /* 'up'|'down'|'caiu' */ final int? velocidade; final String? desde; final bool uplink; final String? ligadoA; }`
  - `MkEstado` ganha `final List<PortaVista> portas`, lido de `j['portas']`. O `estado` é calculado no cliente com a mesma regra de 24 h da Task 1. Função pura `String estadoPorta(Map p, DateTime agora)`, testada.
  - `class Equipamento { id, tipo, nome, ip, local, localNome, origem; Map? estado; int portasTotal, portasUp; List<PortaVista> portas; Map<String, dynamic> uplinks; }` + `ApiClient.equipamentos({String? tipo})`, `equipamento(id)`, `criarEquipamento({tipo, nome, ip, local, community})`, `atualizarEquipamento(id, {...})`, `apagarEquipamento(id)`, `eventosEquipamento(id)`.
  - `PainelPortas({required List<PortaVista> portas, void Function(PortaVista)? aoTocar})`:
    - portas que não começam com `sfp`/`qsfp` em grupos de até 12, cada grupo com 2 fileiras (ímpar em cima, par embaixo, pela ordem natural do número no nome);
    - SFP num grupo à direita;
    - cores pelos tokens (`positiveFill`, `negativeFill`, neutro), uplink com marca (ponto ou borda em `fgPrimary`);
    - `Tooltip` com "nome · com link/sem link/caiu";
    - toque → `aoTocar`;
    - `Semantics(label:)` em cada porta.

- [ ] **Step 1: Write the failing tests**:
  - `ordena ímpar em cima e par embaixo`: com 4 portas `0/1..0/4`, a 1ª linha tem os `Key('porta-0/1')` e `0/3`.
  - `SFP vai para o grupo da direita`.
  - `cores por estado nos dois temas`: a porta `caiu` usa `negativeFill`, nos temas claro e escuro.
  - `estadoPorta respeita 24 h`.
  - `toque chama aoTocar`.
- [ ] **Step 2: Run** `flutter test test/painel_portas_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Grupos de 12 e tamanho da porta ficam a critério do implementador; em tela estreita, o `Wrap` quebra os grupos.
- [ ] **Step 4: Run** `flutter test` e `flutter analyze`. Expected: PASS e analyze limpo.
- [ ] **Step 5: Commit** `feat(painel): desenho frontal das portas (estilo UniFi)`

### Task 10: Flutter, as abas MK | Switch | Firewall e a lista de switches

**Files:**
- Modify: `frontend/lib/screens/dashboard.dart`, `frontend/lib/main.dart` (rotas `/switch/<id>`)
- Create: `frontend/lib/screens/switches.dart` (lista e diálogo "Adicionar switch")
- Test: `frontend/test/switches_test.dart`, `frontend/test/dashboard_test.dart`

**Interfaces:**
- Consumes: Task 9 (`ApiClient.equipamentos`, `criarEquipamento`).
- Produces:
  - o `DashboardScreen` ganha abas no topo (`TabBar` com pill, raio `radius-pill`): **MK** (o conteúdo atual, sem mudança), **Switch** e **Firewall**;
  - cada aba tem um contador de problemas: para MK, o `resumo.fora + com_alerta` atual; para Switch, os equipamentos com status diferente de `no_ar`;
  - `SwitchesTab(api)`: a lista vem agrupada por `localNome` (Sede primeiro), cada linha com bolinha de estado, nome, "N portas · M com link" e "há X" desde o `desde`. O toque leva a `/switch/<id>`;
  - o botão "Adicionar switch" abre um diálogo com nome, IP, local (dropdown "Sede" + MKs de `/api/status`) e community (campo de senha, com dica "em branco = a padrão");
  - a aba Firewall mostra só "Nenhum firewall ainda. O suporte a firewall vem na próxima etapa.", sem botão;
  - o polling da aba Switch segue o intervalo do dashboard atual.

- [ ] **Step 1: Write the failing tests**: as três abas aparecem e a MK é a inicial; a aba Switch lista agrupado, com Sede primeiro; o contador do Switch conta 1 offline; adicionar envia um POST com `local: "sede"` e sem `community` quando o campo está vazio; a aba Firewall mostra o texto e nenhum botão.
- [ ] **Step 2: Run** `flutter test test/switches_test.dart test/dashboard_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test` e `flutter analyze`. Expected: PASS. Os testes antigos do dashboard continuam passando.
- [ ] **Step 5: Commit** `feat(painel): abas MK, Switch e Firewall e lista de switches`

### Task 11: Flutter, a tela do switch e o desenho na tela da MK

**Files:**
- Create: `frontend/lib/screens/switch_detail.dart`
- Modify: `frontend/lib/screens/mk_detail.dart`, `frontend/lib/main.dart`
- Test: `frontend/test/switch_detail_test.dart`, `frontend/test/mk_detail_test.dart`

**Interfaces:**
- Consumes: Tasks 8 e 9.
- Produces:
  - `SwitchDetailScreen(api, id)`, de cima para baixo:
    - cabeçalho com nome, local, bolinha de estado, IP e "há X";
    - `PainelPortas`;
    - abaixo do desenho, um cartão com o detalhe da porta tocada: nome, estado, velocidade ("1 Gbps"/"100 Mbps"), há quanto tempo, e "ligado a: switch <nome>" ou "N aparelhos vigiados", vindo de `uplinks[porta]`;
    - histórico (`/historico`) e eventos do syslog (`/eventos`), reaproveitando os widgets de `widgets/eventos.dart` se servirem;
    - "Renomear" (todos) e "Apagar" (só o manual).
  - `MkDetailScreen`: o `PainelPortas(portas: estado.portas)` entra no topo do `ListView`, antes do `MapaRedeCard`. Porta em `interfaces_vigiadas` ganha `uplink: true` (a marca visual).

- [ ] **Step 1: Write the failing tests**: a tela do switch mostra o desenho com 48+4 portas a partir de um JSON falso; tocar na `0/12` mostra "4 aparelhos vigiados"; o descoberto não tem "Apagar"; a tela da MK mostra `Key('porta-ether1')` quando o estado tem `portas`, e sem `portas` não quebra (estado antigo).
- [ ] **Step 2: Run** `flutter test test/switch_detail_test.dart test/mk_detail_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test` e `flutter analyze`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(painel): tela do switch e desenho das portas na MK`

### Task 12: deploy no CT 119 e conferência

Esta tarefa não é TDD; é operação. Peça confirmação ao dono antes de rodar.

- [ ] **Step 1:** Rodar as suítes do backend e do Flutter e o `flutter analyze` (todos verdes).
- [ ] **Step 2:** `git archive HEAD | ssh root@<IP_PROXMOX> "pct exec 119 -- tar -x -C /opt/nodebeat"`, e no CT `docker compose -f deploy/compose.yml --env-file deploy/.env up -d --build worker api web syslog </dev/null`. Uns 10 s depois, `conntrack -D -p udp --dport 514`, porque o syslog foi recriado.
- [ ] **Step 3:** Conferir:
  - worker sem reinício;
  - `state:mk:*` com `portas`;
  - criar o USW-Pro-48 da sede pela tela (o IP vem do dono);
  - em até 2 min, `state:eq:<id>` com status `no_ar` e 52 portas.
  - Se der `erro_acesso` ou `offline`, testar a rota do CT até a rede do switch (`ip route get <ip>`) e o SNMP de dentro do container.
- [ ] **Step 4:** O dono confere as telas (aba Switch, tela do switch, desenho na MK) nos temas claro e escuro.
- [ ] **Step 5:** Atualizar as notas locais (`docs/andamento.local.md`) e a memória do projeto.

# Monitor de MKs (fase 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Monitorar as MKs dos condomínios (estado, VPN, CPU, memória, uptime, interfaces), avisar via webhook e mostrar tudo num painel interno.

**Architecture:** Uma imagem Python roda dois processos: `worker` (ciclo de 30 s: referência → MKs → motor de alertas → fila do webhook) e `api` (FastAPI para o painel). O motor de alertas (`rules.py`) é puro e sem I/O, testado à exaustão. O estado dele é salvo no Redis a cada ciclo. O painel é Flutter web, servido por nginx com HTTPS, que também faz proxy de `/api`. Tudo sobe com docker compose numa VM do Proxmox.

**Tech Stack:**
- **Back-end:** Python 3.12, FastAPI, uvicorn, motor (MongoDB), redis-py asyncio, librouteros, cryptography (Fernet), argon2-cffi, httpx.
- **Testes:** pytest, pytest-asyncio, fakeredis, mongomock-motor.
- **Front-end:** Flutter 3 (web), pacote `http`.
- **Infra:** nginx, MongoDB 7, Redis 7.

**Spec:** `docs/superpowers/specs/2026-11-11-monitor-mk-design.md`

## Global Constraints

- Ciclo de verificação: **30 s**. Confirmação de alerta: **120 s** seguidos. Retorno: **60 s** estável.
- CPU e memória alertam quando **> 80** (estritamente maior; 80,0 não alerta).
- Conexão RouterOS: **API-SSL, porta 8729, TLS** com certificado fixado por **SHA-256**. Login plain (RouterOS ≥ **6.43**). Só leitura, nunca escreve na MK.
- Referência da sede: **`<HOST_REFERENCIA>`** (DNS + HTTPS `HEAD`, timeout 5 s).
- Histórico no Redis por **90 dias**. Fila do webhook persistida no Redis, ordem preservada, nunca descarta. Backoff de 5 s dobrando até **300 s**.
- Webhook: URL em `MKMON_WEBHOOK_URL`. Se `MKMON_WEBHOOK_TOKEN` estiver definido → `Authorization: Bearer <token>`. Payload exatamente como na spec (`evento`, `tipo`, `mk`, `detalhe`, `inicio`, `fim`, `duracao_s`), com datas ISO 8601 em `America/Sao_Paulo`.
- Senhas das MKs: Fernet com a chave em `MKMON_SECRET_KEY`. **Nunca** saem pela API. Senhas do painel: argon2.
- Nenhuma porta publicada exceto o nginx, preso em `${MKMON_BIND_IP}` (443 e 80→443). Mongo e Redis só na rede do compose, com senha. Redis com `appendonly yes`.
- UI: Trade UI. Tokens copiados para `frontend/design-system/tokens.json`, nunca valores na mão. Temas claro (padrão) e escuro. Números com `tabular-nums` (Space Mono). Status em `positive`/`warning`/`negative`.
- Textos da UI e mensagens em pt-BR. Identificadores de código em inglês, exceto campos do payload/Mongo definidos na spec.

## Review Focus

1. **Worker reiniciado no meio de uma queda** → o `retorno` precisa sair mesmo assim (estado do motor persistido) → teste na Task 1 (`test_dump_load_preserves_open_alert`) e na Task 5.
2. **Interface vigiada renomeada ou removida na MK** → vira `interface_caida` com o detalhe "interface não encontrada", e não é ignorada em silêncio → Task 2 (`test_missing_watched_interface_is_down`).
3. **Webhook fora do ar por horas, ou respondendo 4xx/5xx** → nada se perde, a ordem se mantém e a verificação continua → Task 4 (`test_failed_post_keeps_event_at_head`).
4. **Força bruta no login do painel** → após 5 falhas em 15 min, aquele usuário recebe 429 → Task 6 (`test_login_rate_limited_after_5_failures`).
5. **IP inválido ou trocado no cadastro** (IP do túnel público, IP público privado, texto qualquer) → 422 com mensagem clara → Task 7 (`test_create_mk_rejects_bad_ips`).

---

## Estrutura de arquivos

```
.gitignore                      # .superpowers/, .env, build/, __pycache__/
backend/
  pyproject.toml
  mkmon/
    config.py       # Settings lidas do ambiente
    rules.py        # motor de alertas (puro)
    classify.py     # resultado das sondas → Observation (puro)
    probes.py       # ping e referência
    routeros.py     # cliente RouterOS com TLS fixado
    crypto.py       # Fernet
    history.py      # histórico + estado do painel no Redis
    webhook.py      # fila + envio
    store.py        # MongoDB (mks, users)
    worker.py       # ciclo
    auth.py         # login, sessões, rate limit
    api.py          # rotas FastAPI
    cli.py          # create-user
  scripts/spike_tls.py
  tests/…
frontend/
  design-system/tokens.json
  tool/gen_tokens.dart
  lib/theme/{tokens.g.dart, theme.dart}
  lib/api/client.dart
  lib/screens/{login,dashboard,mk_detail,mk_form}.dart
  test/…
deploy/
  compose.yml  nginx.conf  .env.example
  routeros-monitor-user.rsc
  README.md     # implantação, SonicWall, certificado do nginx
docs/spike-tls.md
```

---

### Task 0: Spike TLS contra MKs reais (throwaway, precisa de humano)

**Files:**
- Create: `backend/scripts/spike_tls.py`, `docs/spike-tls.md`

**Interfaces:**
- Produces: em `docs/spike-tls.md`, as opções de `ssl.SSLContext` que funcionam em v6 e v7 (versão mínima de TLS, `set_ciphers`) e a assinatura exata (exceção ou resposta) que o librouteros devolve num login plain em RouterOS < 6.43. A Task 3 usa as duas coisas.

- [ ] **Step 1:** Escrever `deploy/routeros-monitor-user.rsc` (adiantado da Task 10). Ele cria um certificado autoassinado e assina, liga `api-ssl` com esse certificado e `address=<IP_VM>`, cria o grupo `monitor` com `policy=read,api,!write,!policy,!ssh,!ftp,!winbox,!telnet,!web,!sensitive` e o usuário `monitor` com `address=<IP_VM>`, e adiciona a regra de firewall que aceita ICMP no WAN só de `<IP_PUBLICO_SEDE>`. Os placeholders ficam no topo do arquivo.
- [ ] **Step 2:** Escrever `spike_tls.py <host> <user> <senha>`: conecta com `librouteros.connect(..., port=8729, ssl_wrapper=ctx.wrap_socket)`, usando `ctx` com `check_hostname=False` e `verify_mode=CERT_NONE`. Imprime a versão TLS negociada, a cifra, o SHA-256 do certificado e `/system/resource`.
- [ ] **Step 3 (humano):** aplicar o `.rsc` numa MK v6 e numa v7 e rodar o spike nas duas. Se a v6 falhar no handshake, testar `ctx.minimum_version = TLSVersion.TLSv1` e `ctx.set_ciphers("DEFAULT:@SECLEVEL=0")`.
- [ ] **Step 4:** Registrar os resultados em `docs/spike-tls.md`. **Gate:** se nenhuma configuração funcionar na v6, parar e levar ao usuário.
- [ ] **Step 5:** Commit: `git init` (se preciso), `.gitignore`, `git commit -m "chore: spike TLS RouterOS v6/v7 e script do usuário monitor"`.

---

### Task 1: Esqueleto do back-end + motor de alertas

**Files:**
- Create: `backend/pyproject.toml` (deps da Tech Stack, `[tool.pytest.ini_options] asyncio_mode="auto"`), `backend/mkmon/rules.py`
- Test: `backend/tests/test_rules.py`

**Interfaces:**
- Produces (`mkmon/rules.py`):
  ```python
  class MkState(StrEnum): NO_AR="no_ar"; VPN_CAIU="vpn_caiu"; OFFLINE="offline"; ERRO_ACESSO="erro_acesso"
  @dataclass(frozen=True) class MkRef: id: str; nome: str
  @dataclass(frozen=True) class Observation:
      state: MkState; detalhe: str = ""
      cpu: float | None = None; mem: float | None = None
      ifaces: dict[str, bool] = field(default_factory=dict)   # nome -> running (só as vigiadas)
  @dataclass(frozen=True) class Event:
      evento: Literal["queda","retorno","encerrado"]   # "encerrado" só vai para o histórico
      tipo: str; mk: MkRef | None; detalhe: str
      inicio: datetime; fim: datetime | None; duracao_s: int | None
      def to_payload(self) -> dict   # formato do webhook da spec; mk None -> null
  class AlertEngine:
      def __init__(self, confirm_s: int = 120, recover_s: int = 60)
      frozen: bool                     # True enquanto a última observação da referência falhou
      def observe_reference(self, ok: bool, now: datetime) -> list[Event]
      def observe_mk(self, mk: MkRef, obs: Observation, now: datetime) -> list[Event]   # [] se frozen
      def forget_mk(self, mk_id: str) -> None    # MK removida: descarta sem eventos
      def dump(self) -> dict; @classmethod def load(cls, d: dict) -> "AlertEngine"   # JSON-safe
  ```

O algoritmo, que os testes fixam: cada condição tem uma chave (`"mk"`, `"cpu_alta"`, `"memoria_alta"`, `"interface_caida:<nome>"`, `"sede"`) e um rastreador com as fases `ok → pending → alerting → recovering → ok`:
- **ok + ruim:** vai para `pending`, com `primeiro=now`.
- **pending + ruim:** se `now − primeiro ≥ confirm_s`, vai para `alerting` e emite `queda(inicio=primeiro)`.
- **pending + bom:** volta para `ok`, sem evento.
- **alerting + bom:** vai para `recovering`, com `voltou=now`.
- **recovering + ruim:** volta para `alerting`, sem evento.
- **recovering + bom:** se `now − voltou ≥ recover_s`, vai para `ok` e emite `retorno(inicio=primeiro, fim=voltou, duracao_s=voltou−primeiro)`.
- **Troca de tipo na chave `"mk"` durante `alerting`/`recovering`:** emite `encerrado(tipo antigo)` + `queda(tipo novo, inicio=primeiro)` e mantém `primeiro`. Em `pending`, só atualiza o tipo.
- **MK fora (`state ≠ no_ar`):** as chaves paralelas em `alerting`/`recovering` emitem `encerrado` e são removidas; as em `pending` são removidas sem evento.
- **`observe_reference(False)`:** liga `frozen` e aplica a regra na chave `"sede"`. Com `True`, aplica a regra, desliga `frozen` e manda para `ok` as chaves de MK em `pending` (o tempo de 2 min recomeça). As chaves em `alerting` ficam como estão.

- [ ] **Step 1: Write the failing tests** (`t0 = datetime(2026,11,11,14,0,tzinfo=ZoneInfo("America/Sao_Paulo"))`, um `mk = MkRef("1","Cond. Alfa")` e o helper `at(s) = t0+timedelta(seconds=s)`):
  - `test_short_outage_no_event`: OFFLINE em 0, 30, 60, 90 e NO_AR em 120 → todas as chamadas devolvem `[]`.
  - `test_outage_fires_after_120s`: OFFLINE de 0 a 120 → em 120 sai um único `Event(evento="queda", tipo="offline", inicio=at(0))`. Em 150, `[]`.
  - `test_return_needs_60s_stable`: depois da queda acima, NO_AR em 150 e 180 → `[]`. Em 210 → `retorno` com `inicio=at(0)`, `fim=at(150)` e `duracao_s=150`.
  - `test_flap_during_recovery_no_events`: queda, NO_AR em 150, OFFLINE em 180, NO_AR em 210 → nenhum evento até 270, quando sai o `retorno` com `fim=at(210)`.
  - `test_type_change_while_alerting`: queda VPN_CAIU em 120; OFFLINE em 150 → `[encerrado vpn_caiu, queda offline inicio=at(0)]`.
  - `test_cpu_threshold_strict`: `cpu=80.0` por 180 s → nenhum evento. `cpu=80.1` → `queda cpu_alta` aos 120 s. `cpu=None` não conta como ruim.
  - `test_parallel_alerts_closed_silently_on_mk_down`: `cpu_alta` em alerta, depois MK OFFLINE → `encerrado cpu_alta`, e nenhum `retorno cpu_alta` em momento nenhum.
  - `test_interface_down_alert`: `ifaces={"ether1":False}` por 120 s → `queda interface_caida`, com `"ether1"` no `detalhe`.
  - `test_reference_failure_freezes_mks`: referência falsa de 0 a 300 + MK OFFLINE no mesmo período → só `queda falha_sede` (`mk=None`) aos 120 s. Nenhum evento de MK.
  - `test_reference_recovery_restarts_pending`: MK OFFLINE de 0 a 90, referência falha em 90, volta em 100, MK OFFLINE de 100 em diante → `queda offline` só em 220.
  - `test_dump_load_preserves_open_alert`: queda em 120, depois `AlertEngine.load(json.loads(json.dumps(e.dump())))`. A cópia, com NO_AR em 150 e 210, emite o `retorno`.
  - `test_payload_shape`: `to_payload()` de uma `queda` → chaves exatamente `{"evento","tipo","mk","detalhe","inicio","fim","duracao_s"}`, `mk == {"id":"1","nome":"Cond. Alfa"}` e `inicio == "2026-11-11T14:00:00-03:00"`.
- [ ] **Step 2:** `cd backend && pytest tests/test_rules.py -v` → FAIL (`ModuleNotFoundError: mkmon.rules`).
- [ ] **Step 3:** Implementar `mkmon/rules.py` conforme o bloco Interfaces e o algoritmo acima.
- [ ] **Step 4:** `pytest tests/test_rules.py -v` → todos PASS.
- [ ] **Step 5:** Commit: `feat(backend): motor de alertas com confirmação de 2 min e retorno estável`.

---

### Task 2: Classificação e sondas

**Files:**
- Create: `backend/mkmon/classify.py`, `backend/mkmon/probes.py`
- Test: `backend/tests/test_classify.py`, `backend/tests/test_probes.py`

**Interfaces:**
- Consumes: `MkState`, `Observation` (Task 1); `Snapshot` e `RouterOsError` (Task 3, use o dataclass da Task 3; se esta task vier antes, crie-o em `routeros.py` com estes campos).
- Produces:
  ```python
  # routeros.py (só os tipos)
  @dataclass(frozen=True) class Snapshot: version: str; cpu: float; mem: float; uptime: str; ifaces: dict[str, bool]   # TODAS as interfaces da MK
  class RouterOsError(Exception): detalhe: str
  # classify.py
  def classify(snapshot: Snapshot | None, api_error: str | None, tunnel_ping: bool | None,
               public_ping: bool | None, watched: list[str]) -> Observation
  # probes.py
  async def ping(ip: str) -> bool              # `ping -n -c 2 -W 1 <ip>`, True se exit 0
  async def reference_ok(host: str = "<HOST_REFERENCIA>") -> bool   # httpx HEAD https://host, timeout 5 s; qualquer status HTTP = True; erro de DNS/conexão/timeout = False
  ```
  Regras do `classify`: com snapshot → `NO_AR`, com cpu/mem e só as interfaces vigiadas (uma vigiada que não existir na MK vira `False`, e o `detalhe` lista "interface não encontrada: X"). Sem snapshot e com `tunnel_ping=True` → `ERRO_ACESSO`, com `detalhe=api_error`. Com `tunnel_ping=False`: `public_ping=True` → `VPN_CAIU` ("Túnel sem resposta; IP público responde"), `False` → `OFFLINE` ("Túnel e IP público sem resposta").

- [ ] **Step 1: Failing tests:** `test_snapshot_is_no_ar` (`cpu`/`mem` repassados, `ifaces` filtrado para `watched`); `test_missing_watched_interface_is_down` (`watched=["ether9"]` → `ifaces=={"ether9": False}`, `"interface não encontrada: ether9"` no `detalhe`); `test_api_fail_tunnel_ok_is_erro_acesso`; `test_vpn_caiu`; `test_offline`. Em `test_probes.py`: `test_ping_true_on_exit_0` e `test_ping_false_on_exit_1` (monkeypatch em `asyncio.create_subprocess_exec`); `test_reference_ok_any_status` (`httpx.MockTransport` devolvendo 503 → True); `test_reference_fail_on_connect_error` (transport levantando `httpx.ConnectError` → False). `reference_ok` aceita `transport=` opcional só para teste.
- [ ] **Step 2:** `pytest tests/test_classify.py tests/test_probes.py -v` → FAIL.
- [ ] **Step 3:** Implementar. O `ping` usa `asyncio.create_subprocess_exec` com stdout/stderr em DEVNULL e o IP passado como argumento, nunca por shell.
- [ ] **Step 4:** Mesmos testes → PASS.
- [ ] **Step 5:** Commit: `feat(backend): classificação de estado e sondas ping/referência`.

---

### Task 3: Cliente RouterOS com certificado fixado + criptografia de senha

**Files:**
- Create/Modify: `backend/mkmon/routeros.py`, `backend/mkmon/crypto.py`
- Test: `backend/tests/test_routeros.py`, `backend/tests/test_crypto.py`

**Interfaces:**
- Consumes: os resultados de `docs/spike-tls.md` (opções do contexto SSL e a assinatura de RouterOS < 6.43).
- Produces:
  ```python
  # crypto.py
  def encrypt(plain: str, key: str) -> str ; def decrypt(token: str, key: str) -> str   # Fernet; decrypt com chave errada -> ValueError
  # routeros.py
  class CertMismatch(RouterOsError)          # detalhe "certificado mudou"
  def fetch(host: str, user: str, password: str, pinned_sha256: str | None,
            timeout: float = 5.0) -> tuple[Snapshot, str]   # (snapshot, sha256 visto); síncrono; o worker chama via asyncio.to_thread
  def list_interfaces(host, user, password, pinned_sha256) -> list[tuple[str, bool]]
  def pinned_wrap(ctx: ssl.SSLContext, sock, expected: str | None, seen: list[str]) -> ssl.SSLSocket
  ```
  `pinned_wrap` faz o handshake, calcula o SHA-256 hex minúsculo de `getpeercert(binary_form=True)` e grava esse valor em `seen`. Se `expected` não for None e for diferente, fecha o socket e levanta `CertMismatch`. `fetch` lê `/system/resource` (`version`, `cpu-load`, `free-memory`, `total-memory`, `uptime`) e `/interface` (`name`, `running`), com `mem = 100*(1-free/total)`. Os erros (timeout, login, versão < 6.43 → detalhe "RouterOS anterior a 6.43, atualizar") saem como `RouterOsError(detalhe)`.

- [ ] **Step 1: Failing tests:** `test_encrypt_roundtrip`; `test_decrypt_wrong_key_raises`; `test_pinned_wrap_records_fingerprint` e `test_pinned_wrap_mismatch_raises`, ambos com um servidor TLS local em thread, usando um certificado autoassinado gerado no teste pela `cryptography`; `test_fetch_maps_resource` (monkeypatch em `librouteros.connect`, devolvendo um fake com `path()` → `free-memory=25`, `total-memory=100`, `cpu-load=12` → `mem==75.0`, `cpu==12.0`); `test_old_routeros_detalhe`, simulando a assinatura registrada no spike.
- [ ] **Step 2:** `pytest tests/test_routeros.py tests/test_crypto.py -v` → FAIL.
- [ ] **Step 3:** Implementar. `fetch` passa `ssl_wrapper=lambda s: pinned_wrap(ctx, s, pinned_sha256, seen)` para `librouteros.connect(host, user, password, port=8729, timeout=timeout)`.
- [ ] **Step 4:** Testes → PASS.
- [ ] **Step 5:** Commit: `feat(backend): cliente RouterOS TLS com certificado fixado e senhas cifradas`.

---

### Task 4: Histórico, estado do painel e fila do webhook (Redis)

**Files:**
- Create: `backend/mkmon/history.py`, `backend/mkmon/webhook.py`
- Test: `backend/tests/test_history.py`, `backend/tests/test_webhook.py` (fakeredis.aioredis)

**Interfaces:**
- Consumes: `Event` (Task 1).
- Produces:
  ```python
  # history.py — chaves: hist:<mk_id|sede> (zset, score=epoch de inicio/fim), state:mk:<id> (JSON), engine (JSON)
  async def record(r, ev: Event) -> None          # grava no zset e remove itens com mais de 90 dias
  async def history(r, key: str, days: int = 90) -> list[dict]   # mais recentes primeiro
  async def save_state(r, mk_id: str, row: dict) -> None ; async def load_states(r) -> dict[str, dict]
  async def delete_mk(r, mk_id: str) -> None
  # webhook.py — chave queue:webhook (lista, RPUSH/LINDEX 0/LPOP)
  async def enqueue(r, payload: dict) -> None ; async def pending_count(r) -> int
  async def deliver_once(r, client: httpx.AsyncClient, url: str, token: str | None) -> bool  # envia a cabeça; 2xx -> LPOP, True; senão False e mantém
  async def run_sender(r, client, url, token, sleep=asyncio.sleep) -> None   # loop: backoff 5,10,20…300 s em falha, volta a 5 s em sucesso
  ```
- [ ] **Step 1: Failing tests:** `test_record_and_read_history` (2 eventos → em ordem decrescente); `test_history_prunes_older_than_90_days`; `test_enqueue_preserves_order`; `test_deliver_sends_bearer_token` (MockTransport confere `Authorization: Bearer abc` e o JSON); `test_no_auth_header_without_token`; `test_failed_post_keeps_event_at_head` (500 → False, `pending_count==1`; depois 200 → True e 0); `test_backoff_caps_at_300` (`sleep` falso registra 5,10,20,40,80,160,300,300).
- [ ] **Step 2:** `pytest tests/test_history.py tests/test_webhook.py -v` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit: `feat(backend): histórico de 90 dias e fila persistente do webhook`.

---

### Task 5: Store MongoDB + ciclo do worker

**Files:**
- Create: `backend/mkmon/config.py`, `backend/mkmon/store.py`, `backend/mkmon/worker.py`
- Test: `backend/tests/test_worker.py` (mongomock-motor + fakeredis; `fetch` e as sondas substituídos por fakes)

**Interfaces:**
- Consumes: as Tasks 1 a 4.
- Produces:
  ```python
  # config.py
  @dataclass class Settings: mongo_url; redis_url; secret_key; webhook_url; webhook_token: str|None; reference_host="<HOST_REFERENCIA>"; interval_s=30
  def load_settings() -> Settings     # variáveis MKMON_*; falta obrigatória -> RuntimeError com o nome da variável
  # store.py — coleção mks: {_id, nome, ip_tunel, ip_publico, usuario, senha_cifrada, cert_sha256, interfaces_vigiadas: list[str], criado_em}
  #            coleção users: {_id, usuario (único), senha_hash, criado_em}
  async def list_mks(db) -> list[dict] ; async def get_mk(db, id) -> dict|None ; async def insert_mk(db, doc) -> str
  async def update_mk(db, id, fields: dict) -> bool ; async def delete_mk(db, id) -> bool ; async def set_cert(db, id, sha: str|None) -> None
  # worker.py
  async def run_cycle(db, r, engine: AlertEngine, settings, now: datetime, *, fetch=routeros.fetch, ping=probes.ping, reference_ok=probes.reference_ok) -> None
  async def main() -> None   # carrega o engine do Redis, chama run_cycle a cada interval_s, roda run_sender em paralelo
  ```
  `run_cycle` faz, em ordem: referência → `engine.observe_reference`; se não estiver `frozen`, verifica todas as MKs em paralelo (`asyncio.Semaphore(10)`). O ping só roda se a API falhar. Na primeira conexão sem `cert_sha256`, grava o SHA visto. Em seguida: `classify` → `observe_mk` → `save_state` (status, desde, cpu, mem, uptime, ifaces vigiadas, versão, atualizado_em). O `desde` só muda quando o `status` observado muda em relação à linha salva anteriormente. O painel mostra o estado **observado**; o webhook segue as regras do motor. Cada evento vai para `record`; `queda`/`retorno` também vão para `enqueue(ev.to_payload())`. MKs que saíram do banco recebem `engine.forget_mk` + `history.delete_mk`. Ao final: `r.set("engine", json(engine.dump()))`. Uma exceção numa MK nunca derruba o ciclo (registra no log e segue).

- [ ] **Step 1: Failing tests:** `test_cycle_enqueues_after_confirm` (MK com `fetch` falhando + pings False; ciclos em 0..120 → um payload `offline` na fila); `test_first_contact_pins_cert` (`cert_sha256` None → depois do ciclo, gravado); `test_frozen_skips_mks` (`reference_ok=False` → `fetch` não é chamado); `test_one_mk_exception_does_not_stop_others`; `test_engine_persisted_across_restart` (queda, engine recarregado do Redis, MK volta → `retorno` na fila); `test_load_settings_missing_var`.
- [ ] **Step 2:** `pytest tests/test_worker.py -v` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `pytest -v` (suíte inteira) → PASS.
- [ ] **Step 5:** Commit: `feat(backend): worker com ciclo de 30 s e persistência do motor`.

---

### Task 6: Autenticação do painel

**Files:**
- Create: `backend/mkmon/auth.py`, `backend/mkmon/cli.py`, `backend/mkmon/api.py` (app + rotas `/api/auth/*`)
- Test: `backend/tests/test_auth.py` (FastAPI `TestClient` em modo async via httpx `ASGITransport`)

**Interfaces:**
- Consumes: `store` e `config` (Task 5).
- Produces:
  ```python
  # auth.py — sessões em Redis sess:<token> (secrets.token_urlsafe(32)) TTL 8 h; falhas em login_fail:<usuario> TTL 900 s
  def hash_password(p: str) -> str ; def verify_password(h: str, p: str) -> bool        # argon2
  async def login(db, r, usuario: str, senha: str) -> str   # token; LoginFailed / TooManyAttempts
  async def current_user(request) -> dict    # dependência FastAPI; 401 sem cookie válido
  # api.py
  def create_app(db, r, settings) -> FastAPI
  POST /api/auth/login {usuario, senha} -> 204 + cookie mkmon_sess (HttpOnly, Secure, SameSite=Strict, Path=/api)
  POST /api/auth/logout -> 204 ; GET /api/auth/me -> {usuario}
  # cli.py:  python -m mkmon.cli create-user <usuario>   (lê a senha com getpass, pede confirmação; mínimo 12 caracteres)
  ```
- [ ] **Step 1: Failing tests:** `test_login_sets_secure_cookie` (atributos do cookie conferidos); `test_wrong_password_401` (mesma mensagem genérica "Usuário ou senha inválidos" para usuário inexistente); `test_login_rate_limited_after_5_failures` (6ª tentativa → 429, mesmo com a senha certa); `test_me_requires_session` (401 sem cookie); `test_logout_invalidates_session`; `test_password_stored_as_argon2` (`senha_hash` começa com `$argon2`); `test_cli_rejects_short_password`.
- [ ] **Step 2:** `pytest tests/test_auth.py -v` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit: `feat(backend): login do painel com sessões e limite de tentativas`.

---

### Task 7: API de MKs, status e histórico

**Files:**
- Modify: `backend/mkmon/api.py`
- Test: `backend/tests/test_api_mks.py`

**Interfaces:**
- Consumes: Tasks 3 a 6. Todas as rotas exigem `current_user`.
- Produces (o contrato que o Flutter usa):
  ```
  GET    /api/status -> {resumo:{no_ar:int, com_alerta:int, fora:int}, fila_pendente:int,
                         mks:[{id, nome, status, desde, cpu, mem, uptime, ifaces_ok:int, ifaces_total:int, alertas:[str], versao}]}
         ordem: fora primeiro, depois com alerta, depois por nome. "com_alerta" = no_ar com algum alerta paralelo (cpu/mem acima de 80 ou interface vigiada caída)
  GET    /api/mks/{id} -> {id, nome, ip_tunel, ip_publico, usuario, interfaces_vigiadas, cert_sha256, estado: <linha do status>}   # sem senha
  POST   /api/mks {nome, ip_tunel, ip_publico, usuario, senha} -> 201 {id}
  PUT    /api/mks/{id} {mesmos campos; senha vazia/ausente = mantém}
  DELETE /api/mks/{id} -> 204   (também chama history.delete_mk)
  GET    /api/mks/{id}/interfaces -> [{nome, running}]   (routeros.list_interfaces via to_thread; erro -> 502 {detalhe})
  PUT    /api/mks/{id}/interfaces-vigiadas {interfaces:[str]} -> 204
  POST   /api/mks/{id}/aceitar-certificado -> 204   (set_cert None; o worker fixa o novo no próximo ciclo)
  GET    /api/mks/{id}/historico -> [evento]
  ```
  Validação (pydantic + `ipaddress`): `ip_tunel` precisa ser IPv4 privado; `ip_publico`, IPv4 global; `nome` com 1 a 80 caracteres e único; `usuario`/`senha` não vazios no POST.

- [ ] **Step 1: Failing tests:** `test_create_and_get_never_returns_password` (nenhuma chave contendo `senha` em GET `/mks/{id}` nem em `/status`; senha cifrada no banco ≠ texto puro); `test_create_mk_rejects_bad_ips` (`ip_tunel="8.8.8.8"`, `ip_publico="192.168.0.1"` e `"abc"` → 422); `test_put_empty_password_keeps_old`; `test_status_summary_and_order` (3 estados gravados → contagem e ordem); `test_delete_removes_history`; `test_interfaces_error_returns_502`; `test_accept_certificate_clears_pin`; `test_routes_require_auth` (todas as rotas acima → 401 sem cookie).
- [ ] **Step 2:** `pytest tests/test_api_mks.py -v` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `pytest -v` → PASS.
- [ ] **Step 5:** Commit: `feat(backend): API de cadastro, status e histórico das MKs`.

---

### Task 8: Flutter — tema Trade UI, cliente da API e login

**Files:**
- Create: `frontend/` (`flutter create --platforms web frontend`), `frontend/design-system/tokens.json` (cópia de `C:/Users/User/design-systems/trade-ui/tokens/tokens.json`), `frontend/tool/gen_tokens.dart`, `frontend/lib/theme/tokens.g.dart` (gerado), `frontend/lib/theme/theme.dart`, `frontend/lib/api/client.dart`, `frontend/lib/screens/login.dart`
- Test: `frontend/test/theme_test.dart`, `frontend/test/login_test.dart`

**Interfaces:**
- Consumes: as rotas `/api/auth/*` (Task 6) e `/api/status` (Task 7).
- Produces:
  ```dart
  // tokens.g.dart — gerado por `dart run tool/gen_tokens.dart`, um campo por token semântico (bgPage, bgSurface, fgPrimary, positive, negative, warning, …; space4, radiusXl, …) em TradeTokens.light e TradeTokens.dark
  ThemeData tradeTheme(Brightness b);           // theme.dart; fontes Plus Jakarta Sans / Space Mono
  TextStyle dataStyle(BuildContext c);          // Space Mono + FontFeature.tabularFigures()
  class ApiClient { ApiClient({http.Client? client, String base = '/api'});
    Future<void> login(String u, String p);      // 401 -> ApiError('Usuário ou senha inválidos'); 429 -> ApiError('Muitas tentativas. Aguarde 15 minutos.')
    Future<void> logout(); Future<StatusData> status(); Future<MkDetail> mk(String id);
    Future<String> createMk(MkInput i); Future<void> updateMk(String id, MkInput i); Future<void> deleteMk(String id);
    Future<List<IfaceInfo>> interfaces(String id); Future<void> setWatched(String id, List<String> names);
    Future<void> acceptCert(String id); Future<List<HistEvent>> history(String id); }
  // modelos StatusData, MkRow, MkDetail, MkInput, IfaceInfo, HistEvent em client.dart, com campos idênticos ao JSON da Task 7
  ```
  Antes de escrever a UI, ler `C:/Users/User/design-systems/trade-ui/docs/brand-book.md` e `docs/components/{Button,TextInput,Card,NavBar}.md`, e reproduzir os componentes como widgets Flutter seguindo os mesmos tokens. O tema segue `MediaQuery.platformBrightness`, com um botão de alternância na barra.

- [ ] **Step 1: Failing tests:** `theme_test`: `tradeTheme(Brightness.light).scaffoldBackgroundColor == TradeTokens.light.bgPage` e o mesmo para o dark; contraste do `fgPrimary` sobre o `bgSurface` ≥ 4,5 nos dois temas (função de luminância relativa no teste). `login_test`: com `MockClient` devolvendo 401, aparece "Usuário ou senha inválidos"; com 204, navega para a rota `/painel`.
- [ ] **Step 2:** `cd frontend && flutter test` → FAIL.
- [ ] **Step 3:** Implementar o gerador, o tema, o cliente e a tela de login.
- [ ] **Step 4:** `flutter test` → PASS; `flutter analyze` → sem issues.
- [ ] **Step 5:** Commit: `feat(frontend): tema Trade UI, cliente da API e login`.

---

### Task 9: Flutter — painel, detalhe e cadastro

**Files:**
- Create: `frontend/lib/screens/dashboard.dart`, `mk_detail.dart`, `mk_form.dart`
- Test: `frontend/test/dashboard_test.dart`, `frontend/test/mk_form_test.dart`

**Interfaces:**
- Consumes: `ApiClient` e os modelos (Task 8).
- Produces: as rotas `/painel`, `/mk/:id`, `/mk/novo` e `/mk/:id/editar`.

Comportamento:
- **Painel (layout B da spec):** os três cards de resumo (No ar / Com alerta / Fora) e a tabela com as colunas Condomínio · Status · CPU · Mem · Uptime · Interfaces ("3/3"), ordenável ao clicar no cabeçalho. A ordem padrão é a do servidor. Atualiza a cada **15 s** com `Timer.periodic`, cancelado no `dispose`.
- **Status:** pílula com texto + `desde` relativo ("VPN caiu · 6 min"), em `negative` (fora), `warning` (alerta) ou `positive` (no ar).
- **Banner** "N eventos aguardando envio" quando `fila_pendente > 0`. Sessão expirada (401) → volta ao login.
- **Detalhe:** métricas, lista de interfaces vigiadas com o estado, histórico e os botões "Editar", "Escolher interfaces" (lista de checkboxes vinda de `interfaces()`, salva com `setWatched`), "Aceitar novo certificado" (diálogo Flutter de confirmação) e "Remover".
- **Formulário:** os campos da spec, com a senha obscurecida. Na edição, o placeholder da senha é "deixe vazio para manter". Os erros 422 aparecem no campo correspondente. Depois de criar, abre a escolha de interfaces.

- [ ] **Step 1: Failing tests:** `dashboard_test`: com um `StatusData` falso (1 fora, 1 com alerta, 1 no ar) → os cards mostram 1/1/1, a primeira linha da tabela é a que está fora, e o banner aparece com `fila_pendente: 3`. `mk_form_test`: um 422 com erro em `ip_tunel` mostra a mensagem abaixo desse campo; e a edição com senha vazia envia `MkInput.senha == null`.
- [ ] **Step 2:** `flutter test` → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `flutter test` → PASS; `flutter analyze` limpo. Conferir manualmente os temas claro e escuro com `flutter run -d chrome` e a API local.
- [ ] **Step 5:** Commit: `feat(frontend): painel, detalhe e cadastro de MKs`.

---

### Task 10: Implantação

**Files:**
- Create: `backend/Dockerfile` (python:3.12-slim + `iputils-ping`, usuário não-root), `frontend/Dockerfile` (build `flutter build web` → nginx:1.27-alpine), `deploy/compose.yml`, `deploy/nginx.conf`, `deploy/.env.example`, `deploy/README.md`
- Modify: `deploy/routeros-monitor-user.rsc` (Task 0), se o spike mudou algo

**Interfaces:**
- Consumes: `python -m mkmon.worker`, `uvicorn mkmon.api:app_from_env` (adicionar `app_from_env()` em `api.py`: `load_settings()` + clientes → `create_app`), `python -m mkmon.cli create-user`.

Decisões:
- **compose:** os serviços `mongo` (com usuário e senha, volume), `redis` (`--appendonly yes --requirepass`, volume), `api`, `worker` (`cap_add: [NET_RAW]`) e `web` (nginx). Só o `web` publica `${MKMON_BIND_IP}:443` e `:80`. Todos com `restart: unless-stopped`.
- **nginx:** TLS com o certificado autoassinado montado de `deploy/certs/` (README traz o comando `openssl req -x509 -newkey rsa:2048 -days 825 -nodes -subj "/CN=mkmon"`), redirect 80→443, `location /api/` com proxy para `api:8000`, cabeçalhos `X-Frame-Options DENY`, `X-Content-Type-Options nosniff`, `Referrer-Policy no-referrer`, `Content-Security-Policy "default-src 'self'"` (ajustar se o Flutter web pedir `wasm-unsafe-eval`/fontes).
- **`.env.example`:** `MKMON_MONGO_URL`, `MKMON_REDIS_URL`, `MKMON_SECRET_KEY` (com o comando de geração `python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"`), `MKMON_WEBHOOK_URL`, `MKMON_WEBHOOK_TOKEN`, `MKMON_BIND_IP`, `MONGO_PASSWORD`, `REDIS_PASSWORD`.
- **README:** criar a VM no Proxmox; `docker compose up -d`; criar o primeiro usuário; o `.rsc` por MK; as regras do SonicWall (origem = IP da VM, destino = redes dos condomínios, serviços TCP 8729 + ICMP, nada mais); o aviso de que trocar a `MKMON_SECRET_KEY` inutiliza as senhas guardadas.

- [ ] **Step 1:** Escrever os arquivos.
- [ ] **Step 2:** `docker compose -f deploy/compose.yml config` → sem erro; `docker compose up -d --build` → os 5 serviços `running`.
- [ ] **Step 3:** Verificação ponta a ponta: `python -m mkmon.cli create-user admin` dentro do container `api` → login em `https://<BIND_IP>` funciona. Cadastrar uma MK real → em até 60 s ela aparece "No ar" com CPU, memória e versão. Apontar `MKMON_WEBHOOK_URL` para um endpoint de teste, bloquear temporariamente a 8729 da VM no SonicWall → em ~2,5 min chega `queda erro_acesso` ou `vpn_caiu`; desbloquear → ~1 min depois chega o `retorno`.
- [ ] **Step 4:** Conferir que nada além do nginx escuta fora: `docker compose ps` e `ss -tlnp` na VM, só 80/443 no `BIND_IP`.
- [ ] **Step 5:** Commit: `chore(deploy): compose, nginx HTTPS, script RouterOS e guia de implantação`.

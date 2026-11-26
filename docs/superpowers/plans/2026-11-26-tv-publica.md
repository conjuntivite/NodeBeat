# TV pública de ataques — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `https://<domínio>/tv` abre a TV de ataques sem login, e as rotas que ela usa não devolvem nada além do que a TV mostra.

**Architecture:** Router FastAPI novo `/api/tv` sem dependência de sessão, com respostas montadas por lista fechada de campos a partir do feed (`ataques.agrupar`) e do cache do painel 24 h (stale-while-revalidate: visitante nunca espera nem multiplica o cálculo). nginx redireciona `/tv`, aceita só GET em `/api/tv/`, limita por IP e não repassa cookie. No front, `MapaAtaques(tv: true)` passa a usar as rotas `/tv`, a rota `#/tv` substitui `#/eventos/mapa`, e o tema da TV fica no localStorage.

**Tech Stack:** FastAPI + Motor (pytest + httpx), nginx, Flutter web 3.50 (`material_ui`, `package:web`).

**Spec:** `docs/superpowers/specs/2026-11-26-tv-publica-design.md`

## Global Constraints

- As rotas `/api/tv/*` **nunca** leem cookie/sessão e **nunca** devolvem `usuario`, `mk_id` nem IP de MK.
- Campos do feed público, exatamente: `ip, pais, pais_nome, lat, lon, mk_nome, via, n, sucesso, quando`.
- Campos de cada `logins_externos` público, exatamente: `nome, ip, pais_nome, via, quando`.
- Aviso na TV: `Login de fora aceito: <MK> · <IP>` (sem usuário).
- Nenhuma dependência nova. Tokens via `tokensOf(context)`; textos pt-BR; os dois temas. Não mexer em `lib/widgets/heartbeat.dart`.
- Nunca commitar IP/domínio reais (usar `<domínio>`, `203.0.113.x` em testes).
- nginx: `limit_req` 30 r/min por IP, `burst=20 nodelay`, excesso → 429.

## Review Focus

1. Login aceito no feed público não traz `usuario` (nem `null`) → `tvAtaquesSoCamposPublicos` (Task 1).
2. Painel frio: `/api/tv/tops` responde na hora (vazio) e dispara um único cálculo, mesmo com 20 chamadas simultâneas → `tvTopsNaoEsperaCalculo` (Task 1).
3. `desde=""` ou cursor inválido no público não lê a base desde o início → `tvAtaquesCursorVazioRecusado` (Task 1).
4. Cookie de sessão válido enviado para `/api/tv/*` não muda nada na resposta, e sem cookie funciona → `tvSemSessao` (Task 1).
5. TV recarregada guarda o tema escolhido; abrir `#/tv` sem sessão não vai para o login → `tvAbreSemLogin`, `tvGuardaTema` (Task 3).

---

### Task 1: Rotas públicas `/api/tv`

**Files:**
- Create: `backend/nodebeat/tv.py` (funções puras de filtragem), `backend/tests/test_api_tv.py`
- Modify: `backend/nodebeat/api.py` (router `tv = APIRouter(prefix="/api/tv")`, registrado com `app.include_router(tv)`; reaproveita `_painel_cache`, `_painel_calc`, `_calcular_painel`, `PAINEL_TTL`, `LIMITE_LEITURA`)

**Interfaces — Produces:**
- `tv.CAMPOS_ATAQUE: tuple[str, ...]`, `tv.CAMPOS_LOGIN: tuple[str, ...]` (valores das Global Constraints).
- `tv.ataque_publico(a: dict) -> dict` (só `CAMPOS_ATAQUE`).
- `tv.tops_publicos(acesso: dict | None) -> dict` → `{"total", "top_ips", "top_paises", "por_via", "logins_externos"}`; `top_ips` com só `ip, n, pais, pais_nome`; `None` → `{"total": 0, "top_ips": [], "top_paises": [], "por_via": {}, "logins_externos": []}`.
- `GET /api/tv/ataques?desde=` → `{"cursor", "ataques", "descartados"}` (mesmo formato do feed logado, campos filtrados).
- `GET /api/tv/tops` → saída de `tops_publicos` (formato que `BlocoPainel.fromJson` do front já lê).

- [ ] **Step 1: Testes que falham** em `backend/tests/test_api_tv.py` (fixtures de `tests.test_api_painel`: `anon`, `client`, `db`, `falha`; e um evento de login aceito externo como em `test_api_ataques.py`):
  - `tvAtaquesSoCamposPublicos`: com `anon`, 1 falha + 1 login externo aceito; `set(a) == set(tv.CAMPOS_ATAQUE)` para cada ataque; `"usuario" not in a`.
  - `tvAtaquesCursorVazioRecusado`: `desde=""` → 400; `desde="xyz"` → 400; sem `desde` → `ataques == []` com cursor.
  - `tvTopsCamposPublicos`: com o cache do painel 24 h pronto (chamar `/api/eventos/painel` logado antes), `/api/tv/tops` por `anon` → chaves exatas `{"total","top_ips","top_paises","por_via","logins_externos"}`; cada login com chaves `== set(tv.CAMPOS_LOGIN)`.
  - `tvTopsNaoEsperaCalculo`: cache vazio; 20 chamadas `anon` em `asyncio.gather` respondem 200 com `total == 0`; espiar `api.painel.montar` (monkeypatch contando chamadas) → chamado 1 vez depois de aguardar a tarefa.
  - `tvSemSessao`: as duas rotas respondem 200 com `anon`; e com `client` (logado) a resposta de `/tv/tops` é igual à de `anon`.
  - Teste puro: `tops_publicos(None)` devolve o vazio acima.
- [ ] **Step 2:** `cd backend && pytest tests/test_api_tv.py -q` → FAIL (rotas inexistentes).
- [ ] **Step 3: Implementar.**
  - `/tv/ataques`: igual a `ataques_ao_vivo`, mas `desde == ""` → 400 `"cursor inválido"`; aplica `tv.ataque_publico` em cada grupo.
  - `/tv/tops`: lê `_painel_cache.get(("24h", None))`; se ausente ou mais velho que `PAINEL_TTL`, cria a tarefa em `_painel_calc` (mesma chave, mesmo `add_done_callback`) **sem aguardar**; responde `tv.tops_publicos(cache_atual["blocos"]["acesso"] if houver else None)`.
- [ ] **Step 4:** `pytest -q` completo verde (inclui `test_api_ataques.py`/`test_api_painel.py` sem mudança).
- [ ] **Step 5:** commit `feat(api): rotas publicas da TV com campos fechados`.

### Task 2: nginx da TV pública

**Files:** Modify `deploy/nginx.conf`.

- [ ] **Step 1:** Antes do 1º `server {`: `limit_req_zone $binary_remote_addr zone=tv:10m rate=30r/m;`. No server 443:
  - `location = /tv { return 302 /#/tv; }`
  - `location /api/tv/ { limit_except GET { deny all; } limit_req zone=tv burst=20 nodelay; limit_req_status 429; proxy_set_header Cookie ""; ` + o mesmo `set $api`/`proxy_pass`/headers do `location /api/` }`.
- [ ] **Step 2:** Validar: `docker run --rm -v "$PWD/deploy/nginx.conf:/etc/nginx/conf.d/default.conf:ro" --add-host api:127.0.0.1 nginx:alpine nginx -t` → falha só por falta de certificado é aceitável se o resto passar; alternativa: o mesmo comando dentro do CT 119 no container `web` (`nginx -t`) no deploy (Task 4).
- [ ] **Step 3:** commit `feat(deploy): /tv publica no nginx com limite por IP e sem cookie`.

### Task 3: Front da TV sem login

**Files:**
- Modify: `frontend/lib/api/client.dart` (`ataquesTv`, `topsTv`), `frontend/lib/widgets/mapa_ataques.dart`, `frontend/lib/screens/mapa_ataques_tv.dart`, `frontend/lib/main.dart` (rota `['tv']`, sai `['eventos','mapa']`), `frontend/lib/ataques/aba.dart`, `aba_stub.dart`, `aba_web.dart`
- Test: `frontend/test/mapa_ataques_tv_test.dart`, `frontend/test/mapa_ataques_test.dart`

**Interfaces — Consumes:** Task 1 (`/api/tv/ataques`, `/api/tv/tops`). **Produces:**
- `ApiClient.ataquesTv({String? desde}) -> Future<FeedAtaques>` (`/tv/ataques`), `ApiClient.topsTv() -> Future<BlocoPainel>` (`/tv/tops`).
- `aba.dart`: `String? temaTvSalvo()`, `void salvarTemaTv(String tema)` (`'claro'|'escuro'`; web = `localStorage['nodebeat_tv_tema']`; stub = variável em memória). `abrirMapaEmNovaAba()` abre `/tv`.

- [ ] **Step 1: Testes que falham:**
  - `tvAbreSemLogin`: `NodeBeatApp` com mock que responde 401 em tudo fora de `/api/tv/*`; `pushReplacementNamed('/tv')` → `MapaAtaquesTvScreen` na tela, `LoginScreen` ausente, e nenhum pedido a `/api/eventos/*` (registrar paths do mock). Substitui `tvVaiProLoginEVolta`.
  - `tvGuardaTema`: `salvarTemaTv('escuro')` antes; abrir a TV → `themeMode.value == ThemeMode.dark`; tocar no `ThemeToggle` → `temaTvSalvo() == 'claro'`. Ajustar `tvSegueTemaEAlterna` a isso.
  - `avisoTvSemUsuario` (em `mapa_ataques_test.dart`, `tv: true`, feed de `/api/tv/ataques` com `sucesso: true` sem `usuario`) → acha `Login de fora aceito: <MK> · 203.0.113.5` e nenhum texto com `?`.
  - Ajustar o mock `_Servidor` para responder `/api/tv/ataques` e `/api/tv/tops` (tops = o bloco `acesso` direto) quando `tv: true`; testes do popup (`tv: false`) seguem nas rotas logadas.
- [ ] **Step 2:** `cd frontend && flutter test` → os novos falham.
- [ ] **Step 3: Implementar.**
  - `MapaAtaques`: com `tv: true` usa `api.ataquesTv`/`api.topsTv`; com `tv: false`, as rotas logadas de hoje. Aviso: usuário só entra no texto quando não nulo (`'Login de fora aceito: ${a.mk}${a.usuario == null ? '' : ' · ${a.usuario}'} · ${a.ip}'`).
  - TV: sem `aoExpirarSessao`; `initState` aplica `temaTvSalvo()` em `themeMode`; ouve `themeMode` e chama `salvarTemaTv` (remove o listener no `dispose`).
  - `main.dart`: `['tv'] => MapaAtaquesTvScreen(api: api)`; remover `['eventos', 'mapa']`.
- [ ] **Step 4:** `flutter test` e `flutter analyze` verdes.
- [ ] **Step 5:** commit `feat(front): TV publica em #/tv sem login, tema no navegador`.

### Task 4: Revisão final e deploy (com o dono)

- [ ] Revisão da branch inteira com foco nas Global Constraints (nenhum `usuario`/cookie no caminho público).
- [ ] Mesclar na main; push e deploy de `api web` no CT 119 só com o ok do dono; `nginx -t` no container `web`.
- [ ] Conferir: `curl -sk https://<ip>/api/tv/tops` sem cookie → 200 sem `usuario`; `POST` → 403; 60 chamadas seguidas → 429; abrir `https://<ip>/tv` no Chrome numa janela sem login → mapa, lista e tops.

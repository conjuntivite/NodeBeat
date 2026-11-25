# Mapa de ataques ao vivo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mapa-múndi ao vivo das tentativas de login de fora nas MKs, dentro do popup de Acesso e numa aba própria para a TV do NOC.

**Architecture:** O backend ganha geolocalização por país offline (faixas IPv4 em memória + `bisect`) e um feed `GET /api/eventos/ataques?desde=<cursor>` que agrupa as tentativas novas por (IP, MK, via). O front consulta a cada 5 s, distribui as linhas ao longo da janela e desenha mapa e arcos com `CustomPainter`. O rodapé e o aviso de login aceito reaproveitam `GET /api/eventos/painel?periodo=24h`, que passa a trazer o país.

**Tech Stack:** Python 3.14 / FastAPI / Motor (Mongo) · Flutter web 3.50 (`material_ui`, `http`, `web`) · sem dependência nova.

**Spec:** `docs/superpowers/specs/2026-11-25-mapa-ataques-design.md`

## Global Constraints

- Nenhuma dependência nova (pip ou pub). Geolocalização offline: nada de IP sai para serviço externo.
- Base de IPs: DB-IP "IP to Country Lite" (CC-BY 4.0). O texto `IP data by DB-IP` fica visível no mapa (popup e TV).
- Contorno dos continentes: Natural Earth 110m land (domínio público).
- Só MKs entram no feed (`mk_id` que começa com `eq:` fica de fora), e "externo" segue `painel.categoria`: subtipos `falha_externa` e `login_externo_ok`.
- O feed nunca devolve o IP público nem o IP do túnel da MK; só `mk_nome`.
- Destino fixo de todas as linhas: oeste de SC, lat `-27.10`, lon `-52.62`.
- Consulta ao feed a cada **5 s**; rodapé e avisos (`painel?periodo=24h`) a cada **60 s**.
- Animação: viagem **1,5 s**, linha cheia **2 s**, sumiço **1 s**. Teto de **60** linhas ativas. No máximo **200** grupos por resposta do feed.
- Login aceito: cor `negative`, linha mais grossa, aviso fixo com botão "Ciente" que vale só para a aba.
- "Sem dados": o indicador "● ao vivo" vira âmbar (`warning`) com "sem dados há X min" depois de **30 s** sem consulta bem-sucedida.
- Aba da TV: rota `#/eventos/mapa`, fora do `AppShell`, tema escuro fixo.
- Textos de tela em pt-BR. Tokens do design system do NodeBeat (`TradeTokens`, `chart1..6`, `negative`, `warning`), sem cor na mão.
- Não mexer em `frontend/lib/widgets/heartbeat.dart`.

## Review Focus

1. **Rajada maior que o limite de leitura** (ex.: 700/h numa MK, ou o feed parado por minutos): o cursor avança sem perder nem repetir evento entre chamadas → teste `test_feed_cursor_em_rajada` (Task 2).
2. **IP sem país** (fora da base, IPv6 ou faixa reservada): conta no rodapé, sem linha e sem erro → `test_pais_desconhecido` (Task 1) e `filaIgnoraSemCoordenada` (Task 4).
3. **Feed falhando** (rede da TV cai, 500): a tela mostra "sem dados há X min" e volta sozinha → teste de widget `indicadorSemDados` (Task 5).
4. **Sessão expirada (401) na TV:** vai para o login e volta ao mapa depois de entrar → `tvVaiProLoginEVolta` (Task 6).
5. **TV aberta por dias:** linhas terminadas saem da memória e as ativas nunca passam de 60 → `filaRespeitaTeto` e `filaRemoveTerminadas` (Task 4).

---

### Task 1: Geolocalização por país (backend)

**Files:**
- Create: `backend/scripts/geoip_atualizar.py` (gera os dados; roda à mão, uma vez por mês)
- Create: `backend/nodebeat/dados/geoip-pais.csv.gz`, `backend/nodebeat/dados/paises.csv` (gerados e commitados)
- Create: `backend/nodebeat/geoip.py`
- Modify: `backend/pyproject.toml` (adicionar `[tool.setuptools.package-data] nodebeat = ["dados/*"]`; sem isso o `pip install .` da imagem não leva os dados)
- Test: `backend/tests/test_geoip.py`

**Interfaces:**
- Produces: `geoip.pais(ip: str) -> Pais | None`, com `@dataclass(frozen=True) class Pais: cc: str; nome: str; lat: float; lon: float`. Carrega os arquivos uma vez (preguiçoso, em cache de módulo). `geoip.carregar(faixas_csv_gz: Path, paises_csv: Path) -> None` existe para os testes apontarem arquivos pequenos.

- [ ] **Step 1: Gerar os dados.** `geoip_atualizar.py` baixa `https://download.db-ip.com/free/dbip-country-lite-<AAAA-MM>.csv.gz` e mantém só IPv4. Grava `geoip-pais.csv.gz` com as linhas `inicio_int,fim_int,CC`, ordenadas por início. `paises.csv` tem as colunas `cc,nome,lat,lon`: centroide de cada país e nome em pt-BR, gerado uma vez a partir de uma tabela pública de centroides (anotar a fonte no topo do script). Rodar e commitar a saída.
- [ ] **Step 2: Testes que falham** em `test_geoip.py`, com um CSV mínimo de fixture (`tmp_path`):
  - `test_pais_por_faixa`: faixa `1.0.0.0–1.0.0.255 → AU`; `pais("1.0.0.0").cc == "AU"`, `pais("1.0.0.255").cc == "AU"`, `pais("1.0.1.0") is None`.
  - `test_pais_desconhecido`: `pais("2001:db8::1") is None`, `pais("lixo") is None`, `pais("10.0.0.1") is None`.
  - `test_pais_tem_centroide`: o resultado traz `nome`, `lat` e `lon` do `paises.csv`.
  - `test_dados_reais_carregam`: com os arquivos commitados, `pais("8.8.8.8").cc == "US"`.
- [ ] **Step 3: Rodar** `cd backend && .venv/Scripts/python -m pytest tests/test_geoip.py -q`. Esperado: FAIL (módulo não existe).
- [ ] **Step 4: Implementar `geoip.py`.** Duas listas paralelas (`inicios`, `fins`/`cc`) e `bisect_right(inicios, n) - 1`, conferindo `n <= fim`. Endereço inválido ou IPv6 → `None`.
- [ ] **Step 5: Rodar de novo.** Esperado: PASS.
- [ ] **Step 6: Commit** `feat(backend): geolocalizacao offline por pais (DB-IP Lite)`

### Task 2: Feed de ataques ao vivo (backend)

**Files:**
- Create: `backend/nodebeat/ataques.py` (puro)
- Modify: `backend/nodebeat/store.py` (nova função de leitura)
- Modify: `backend/nodebeat/api.py` (rota ao lado de `/eventos/painel`, ~linha 479)
- Test: `backend/tests/test_ataques.py`, `backend/tests/test_api_ataques.py`

**Interfaces:**
- Consumes: `geoip.pais` (Task 1); `painel.categoria(ev, ctx)`, `painel.falha_login(ev)`, `painel.Ctx`.
- Produces:
  - `store.listar_eventos_apos(db, cursor: ObjectId | None, limite: int) -> list[dict]`: eventos com `_id > cursor`, só MKs (`mk_id` sem `eq:`), `tipo ∈ {"login_falha","erro","login"}`, ordem crescente de `_id`. **Mantém `_id`**, com datas em UTC aware como em `_utc`.
  - `ataques.agrupar(eventos: list[dict], nomes: dict[str, str], ctx: Ctx, pais_de=geoip.pais, max_grupos: int = 200) -> tuple[list[dict], int]`: devolve `(grupos, descartados)`.
  - `GET /api/eventos/ataques?desde=<cursor>` (usuário logado) → `{"cursor": str, "ataques": [...], "descartados": int}`. Cada ataque tem `{ip, pais, pais_nome, lat, lon, mk_nome, via, n, sucesso, quando, usuario}`. `pais`, `pais_nome`, `lat` e `lon` são `null` quando o país é desconhecido. `usuario` só vem quando `sucesso` é verdadeiro; `quando` é o ISO do evento mais recente do grupo.
  - Constante `LIMITE_LEITURA = 5000` em `api.py`.

- [ ] **Step 1: Testes que falham em `test_ataques.py`** (com `CTX = Ctx(["10.1.0.0/16"], ["198.51.100.7"])` e um `pais_de` falso):
  - `test_agrupa_por_ip_mk_via`: três falhas SSH de `203.0.113.5` na MK A e uma via FTP → 2 grupos, `n` 3 e 1.
  - `test_ignora_interno_e_sede`: falhas de `10.1.2.3` e `198.51.100.7` não entram.
  - `test_login_aceito`: evento `login` do usuário `admin`, IP externo → `sucesso: True`, `usuario: "admin"`. Usuário `monitor` não entra.
  - `test_ignora_mk_desconhecida`: `mk_id` fora de `nomes` não entra.
  - `test_teto_de_grupos`: 250 IPs distintos com `max_grupos=200` → 200 grupos (os mais recentes) e `descartados == 50`.
  - `test_sem_ip_publico`: nenhum grupo tem chave além das do contrato.
- [ ] **Step 2: Testes que falham em `test_api_ataques.py`** (fixtures como em `test_api_painel.py`; eventos inseridos direto em `db.eventos`):
  - `test_primeira_chamada_so_cursor`: sem `desde` → `ataques == []` e `cursor` igual ao `_id` do último evento (string). Banco vazio → `cursor == ""`.
  - `test_feed_traz_so_novos`: com o cursor da primeira chamada, insere 2 falhas externas → a segunda chamada traz esses 2 e um cursor novo. A terceira chamada traz `[]`.
  - `test_feed_cursor_em_rajada`: com `LIMITE_LEITURA` trocado para 3 via `monkeypatch`, insere 7 falhas de IPs distintos depois do cursor. Três chamadas encadeadas somam exatamente os 7 IPs, sem repetir.
  - `test_cursor_invalido`: `desde=xyz` → 400.
  - `test_exige_login`: sem sessão → 401.
- [ ] **Step 3: Rodar** `cd backend && .venv/Scripts/python -m pytest tests/test_ataques.py tests/test_api_ataques.py -q`. Esperado: FAIL.
- [ ] **Step 4: Implementar.** A rota lê `LIMITE_LEITURA` eventos depois do cursor e devolve como cursor o `_id` do último **lido**, mesmo que ele não vire ataque. O IP vem de `falha_login(ev)` nas falhas e de `campos.ip` no `login`. Sem `desde`, a rota busca só o maior `_id` (sort `-1`, limit 1).
- [ ] **Step 5: Rodar de novo.** Esperado: PASS. Rodar também a suíte inteira: `.venv/Scripts/python -m pytest -q`.
- [ ] **Step 6: Commit** `feat(backend): feed de ataques ao vivo por cursor`

### Task 3: País no bloco Acesso do painel (backend)

**Files:**
- Modify: `backend/nodebeat/painel.py` (`Ctx` e montagem do bloco `acesso`, ~linhas 26-30 e 205-211)
- Modify: `backend/nodebeat/api.py:489` (passar `geoip.pais` ao `Ctx`)
- Test: `backend/tests/test_painel.py`

**Interfaces:**
- Consumes: `geoip.pais` (Task 1).
- Produces: `Ctx` ganha o campo `pais_de: Callable[[str], Pais | None] = lambda ip: None`. O bloco `acesso` passa a ter:
  - `top_ips: [{ip, n, pais, pais_nome}]`;
  - `top_paises: [{pais, pais_nome, n}]`, top 5 sobre **todas** as falhas externas; país desconhecido entra como `pais: null, pais_nome: "Desconhecido"`;
  - `logins_externos[*]` com `pais_nome`.

- [ ] **Step 1: Testes que falham:**
  - `test_acesso_top_paises`: 3 falhas de um IP "BR" e 1 de um IP "NL" (com `pais_de` falso no `Ctx`) → `top_paises[0] == {"pais": "BR", "pais_nome": "Brasil", "n": 3}`.
  - `test_acesso_top_ips_com_pais`: `top_ips[0]["pais_nome"]` preenchido.
  - `test_acesso_pais_desconhecido`: `pais_de` devolvendo `None` → `{"pais": None, "pais_nome": "Desconhecido", ...}`.
- [ ] **Step 2: Rodar** `cd backend && .venv/Scripts/python -m pytest tests/test_painel.py -q`. Esperado: FAIL nesses 3 e os antigos verdes.
- [ ] **Step 3: Implementar.** Contar países no mesmo laço que conta `ips`; o `Ctx` padrão mantém os testes antigos sem mudança.
- [ ] **Step 4: Rodar a suíte inteira.** Esperado: PASS.
- [ ] **Step 5: Commit** `feat(backend): pais de origem no bloco Acesso`

### Task 4: Dados, geometria e fila de animação (front, sem UI)

**Files:**
- Modify: `frontend/lib/api/client.dart` (modelos e método)
- Create: `frontend/lib/ataques/geo.dart`, `frontend/lib/ataques/fila.dart`
- Test: `frontend/test/ataques_test.dart`

**Interfaces:**
- Consumes: o contrato do feed (Task 2) e os campos novos do painel (Task 3).
- Produces:
  - `class Ataque { ip, pais?, paisNome?, lat?, lon?, mkNome, via, n, sucesso, quando: DateTime, usuario? ; Ataque.fromJson }`
  - `class FeedAtaques { cursor: String; ataques: List<Ataque>; descartados: int }`
  - `ApiClient.ataques({String? desde}) -> Future<FeedAtaques>`
  - `ContaIp` ganha `pais`/`paisNome` (opcionais); `BlocoPainel` ganha `topPaises: List<Map<String, dynamic>>`.
  - `geo.dart`: `const destinoLat = -27.10, destinoLon = -52.62;` `Offset projetar(double lat, double lon, Size s)` (equiretangular, lon −180..180 → 0..w; lat 84..−58 → 0..h, com corte nesses limites); `Offset controleArco(Offset a, Offset b)` (ponto médio deslocado para cima em 30% da distância); `Offset pontoNoArco(Offset a, Offset c, Offset b, double t)` (Bézier quadrática).
  - `fila.dart`: `class LinhaAtiva { final Ataque ataque; final DateTime inicio; }`; `class FilaAtaques { FilaAtaques({int teto = 60}); void receber(List<Ataque> lote, DateTime agora, {Duration janela = const Duration(seconds: 5)}); List<LinhaAtiva> ativas(DateTime agora); int get descartados; }`; `({double cabeca, double opacidade}) fase(Duration idade)`, com as constantes `viagem = 1500ms`, `cheia = 2000ms` e `sumico = 1000ms`.

- [ ] **Step 1: Testes que falham em `ataques_test.dart`:**
  - `ataqueFromJson`: JSON de exemplo do contrato → campos certos; `lat` nulo aceito.
  - `projetaCantos`: `projetar(84, -180, Size(360,142)) == Offset(0,0)`; `projetar(-58, 180, ...) == Offset(360,142)`.
  - `arcoComecaETermina`: `pontoNoArco(a,c,b,0) == a`, `pontoNoArco(a,c,b,1) == b`; `controleArco(a,b).dy < min(a.dy,b.dy)`.
  - `faseViagemCheiaSumico`: `fase(0ms).cabeca == 0`; `fase(1500ms).cabeca == 1 && opacidade == 1`; `fase(3500ms).opacidade == 1`; `fase(4500ms).opacidade == 0`.
  - `filaEspalhaNaJanela`: lote de 5 recebido em `t0` → em `t0` só 1 ativa; em `t0+5s` as 5.
  - `filaIgnoraSemCoordenada`: ataque com `lat == null` nunca vira linha ativa.
  - `filaRespeitaTeto`: lote de 100 com `teto: 60`, olhando em `t0+5s` → `ativas().length <= 60` e `descartados == 40`.
  - `filaRemoveTerminadas`: em `t0 + 5s + 4,5s + 1ms`, nada ativo e a lista interna vazia.
  - `apiAtaquesUsaCursor`: `ApiClient` com `MockClient` → a URL chamada é `/api/eventos/ataques?desde=abc`.
- [ ] **Step 2: Rodar** `cd frontend && flutter test test/ataques_test.dart`. Esperado: FAIL.
- [ ] **Step 3: Implementar** modelos, `geo.dart` e `fila.dart`. A fila descarta da cauda do agendamento quando passa do teto.
- [ ] **Step 4: Rodar de novo.** Esperado: PASS. Rodar `flutter analyze`: sem avisos novos.
- [ ] **Step 5: Commit** `feat(front): modelos, geometria e fila do mapa de ataques`

### Task 5: Widget do mapa ao vivo

**Files:**
- Create: `frontend/tool/gerar_mapa.py` (converte o Natural Earth 110m land para o asset; roda uma vez) e `frontend/assets/ataques/terra.json` (gerado, < 150 KB: lista de polígonos `[[lon,lat],...]` simplificados)
- Modify: `frontend/pubspec.yaml` (asset `assets/ataques/`)
- Create: `frontend/lib/widgets/mapa_ataques.dart`
- Test: `frontend/test/mapa_ataques_test.dart`

**Interfaces:**
- Consumes: Task 4 inteira; `ApiClient.painelEventos('24h')`.
- Produces: `class MapaAtaques extends StatefulWidget { const MapaAtaques({required ApiClient api, bool tv = false, VoidCallback? aoExpirarSessao, Duration intervalo = const Duration(seconds: 5), Duration intervaloRodape = const Duration(seconds: 60)}); }`. Os intervalos são injetáveis para os testes.
  - Camadas: o mapa estático vai num `CustomPainter` com `RepaintBoundary` e `shouldRepaint` falso. As linhas vão num segundo painter, movido por um único `Ticker`.
  - A cor de cada via vem de `chart1..5` (ssh, telnet, ftp, api, winbox; outras → `chart6`). O login aceito usa `negative`, com traço 2× mais grosso.
  - Sobreposições: legenda "Todas as MKs, ao vivo", indicador "● ao vivo" / "sem dados há X min" (âmbar depois de 30 s) e o crédito "IP data by DB-IP".
  - Faixa de avisos de login aceito: vem de `loginsExternos` (painel 24 h) mais os ataques com `sucesso`. Chave `'$mk|$ip|$usuario|$quando'`. "Ciente" guarda a chave num `Set` do `State`.
  - Com `tv: true`, mostra o rodapé (top países, top IPs, barras por via) a partir do painel 24 h.
  - Um `ApiError` com status 401 chama `aoExpirarSessao`. Outros erros só alimentam o indicador.
  - `dispose` cancela os timers e o ticker.

- [ ] **Step 1: Gerar o asset** com `tool/gerar_mapa.py` (anotar no topo a URL de origem do Natural Earth). Conferir o tamanho.
- [ ] **Step 2: Testes de widget que falham** (`MockClient` respondendo feed e painel; `tester.pump` com intervalos curtos):
  - `desenhaLinhaDoFeed`: o feed devolve 1 ataque → depois de um `pump`, o painter de linhas tem 1 linha ativa (expor `@visibleForTesting int get linhasAtivas`).
  - `indicadorSemDados`: o feed responde 500 → depois de 31 s, aparece o texto `sem dados há`. Quando o feed volta a responder 200, aparece `ao vivo`.
  - `avisoLoginAceito`: o painel traz 1 item em `logins_externos` → a faixa mostra o nome da MK; tocar em "Ciente" esconde a faixa.
  - `sessaoExpiradaChamaCallback`: feed 401 → `aoExpirarSessao` chamado uma vez.
  - `rodapeSoNaTv`: `tv: false` não mostra "Top países"; `tv: true` mostra.
  - `creditoDbIp`: o texto `IP data by DB-IP` está presente.
- [ ] **Step 3: Rodar** `cd frontend && flutter test test/mapa_ataques_test.dart`. Esperado: FAIL.
- [ ] **Step 4: Implementar `mapa_ataques.dart`.** A primeira chamada do feed vai sem `desde` (começa do agora).
- [ ] **Step 5: Rodar de novo.** Esperado: PASS. Conferir os temas claro e escuro com `flutter run -d chrome`.
- [ ] **Step 6: Commit** `feat(front): mapa de ataques ao vivo`

### Task 6: Popup maior, aba da TV e volta pelo login

**Files:**
- Modify: `frontend/lib/screens/painel_eventos.dart` (`_abrirDetalhe` ~l.289 e `_detalheAcesso`)
- Create: `frontend/lib/screens/mapa_ataques_tv.dart`
- Create: `frontend/lib/ataques/aba.dart` + `aba_stub.dart` + `aba_web.dart` (import condicional, no mesmo padrão de `audio/monitor_sound.dart`)
- Modify: `frontend/lib/main.dart` (rota) e `frontend/lib/screens/login.dart` (destino depois do login)
- Test: `frontend/test/painel_eventos_test.dart`, `frontend/test/mapa_ataques_tv_test.dart`, `frontend/test/login_test.dart`

**Interfaces:**
- Consumes: `MapaAtaques` (Task 5).
- Produces:
  - `aba.dart`: `void abrirMapaEmNovaAba()` (web: `window.open('${Uri.base.path}#/eventos/mapa', '_blank')`; stub: nada) e `bool abaVisivel()` (web: `document.visibilityState == 'visible'`; stub: `true`). O `MapaAtaques` pula a consulta quando `abaVisivel()` é falso.
  - `MapaAtaquesTvScreen({required ApiClient api})`: `Theme` escuro fixo (`tradeTheme(Brightness.dark)`), sem `AppShell`. Cabeçalho: logo, "Ataques às MKs" e relógio. O corpo é `MapaAtaques(api, tv: true, aoExpirarSessao: → pushReplacementNamed('/login', arguments: '/eventos/mapa'))`.
  - Rota `['eventos', 'mapa'] => MapaAtaquesTvScreen(api: api)` em `main.dart`. Também em `onGenerateInitialRoutes`, para recarregar a aba sem empilhar o login.
  - `LoginScreen({required ApiClient api, String depois = '/painel'})`: a rota `_` passa `s.arguments is String ? s.arguments : '/painel'`.
  - Popup: só para `cat == 'acesso'`, o `Dialog` passa a usar `insetPadding` de 4% e `SizedBox` com 92% de largura × 92% de altura da janela. Por dentro: `MapaAtaques(api)` em cima (~60% da altura) e o conteúdo atual de `_detalheAcesso` embaixo, rolável. Botão "Abrir em tela cheia" (ícone `open_in_new`, com `tooltip`) ao lado do fechar, chamando `abrirMapaEmNovaAba()`. As outras categorias continuam iguais (760 px).

- [ ] **Step 1: Testes que falham:**
  - `popupAcessoTemMapaEBotao` (em `painel_eventos_test.dart`): abrir o detalhe de Acesso → encontra `MapaAtaques` e o tooltip "Abrir em tela cheia". O detalhe de VPN não tem `MapaAtaques`.
  - `tvVaiProLoginEVolta` (`mapa_ataques_tv_test.dart`): feed 401 → aparece a `LoginScreen`. Depois de um login com sucesso (mock 200), a rota atual é `/eventos/mapa`.
  - `tvTemaEscuro`: o `Theme.of` dentro da TV tem `brightness == Brightness.dark` mesmo com `themeMode` claro.
  - `loginVaiParaDestino` (`login_test.dart`): `LoginScreen(depois: '/eventos/mapa')` navega para essa rota; sem o parâmetro, continua indo para `/painel`.
- [ ] **Step 2: Rodar** `cd frontend && flutter test test/painel_eventos_test.dart test/mapa_ataques_tv_test.dart test/login_test.dart`. Esperado: FAIL.
- [ ] **Step 3: Implementar.**
- [ ] **Step 4: Rodar a suíte inteira** com `flutter test` e depois `flutter analyze`. Esperado: tudo verde. Conferir no Chrome o popup nos dois temas e a aba da TV em 1920×1080.
- [ ] **Step 5: Commit** `feat(front): popup de Acesso com mapa e aba da TV`

### Task 7: Revisão final e deploy (com o dono)

- [ ] **Step 1:** Rodar a suíte inteira do backend e do front e `flutter analyze`. Esperado: tudo verde.
- [ ] **Step 2:** Revisão do branch inteiro (`superpowers:requesting-code-review`).
- [ ] **Step 3:** **Pedir confirmação ao dono** antes do deploy. Depois, fazer o deploy pelo procedimento de sempre no CT 119 (`git archive HEAD | ssh ... tar -x -C /opt/nodebeat`, depois `docker compose ... up -d --build api worker web`).
- [ ] **Step 4:** Conferir em produção que o `GET /api/eventos/ataques` responde, e que a aba `#/eventos/mapa` mostra linhas reais em até 1 min.
- [ ] **Step 5:** Avisar o dono para criar pelo painel de usuários o usuário comum da TV, e para atualizar a base do DB-IP todo mês (`backend/scripts/geoip_atualizar.py`, depois commit e deploy).

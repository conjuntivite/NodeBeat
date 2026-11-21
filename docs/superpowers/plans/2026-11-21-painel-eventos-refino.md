# Painel de eventos: refino visual — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesenhar a tela Eventos (cor ciano, veredito em uma frase, cards que explicam o número e dizem se é bom ou ruim, gráficos refinados) com `estado` e `delta_pct` novos no backend.

**Architecture:** `painel.montar` ganha `resumo_estado` (não altera campos atuais). O Flutter lê esse campo, e a tela é recomposta em widgets pequenos (`painel_textos`, `painel_cards`) mantendo `painel_eventos.dart` como orquestrador. A cor de marca muda só na cópia do projeto (`frontend/design-system/tokens.json` → `tool/gen_tokens.dart` → `tokens.g.dart`).

**Tech Stack:** Python/FastAPI + pytest (backend/); Flutter (`material_ui`), `fl_chart`, `flutter test` (frontend/).

**Spec:** `docs/superpowers/specs/2026-11-21-painel-eventos-refino-design.md`. Mockups: `.superpowers/brainstorm/*/content/eventos-direcao-a.html` e `eventos-cor-marca.html` (opção A, ciano).

## Global Constraints
- Trade UI: só tokens (`tokensOf(context)`, `TradeType`), nunca cor/espaço/raio literal; os dois temas; texto ≥ 4,5:1; números com `tabular-nums`; variação com seta `↗`/`↘`; uma cor de marca por tela; grade de 4 px; cards `radius-xl`, padding `space-6`, gap `space-4`.
- Cor de marca ciano `#22D3EE` nos dois temas, texto sobre ela `#04222A`; link sobre superfície `brand-text` claro `#09768A`, escuro `#5BE0F5`.
- Não alterar o Trade UI global nem `C:/Users/User/design-systems/`. Não alterar campos existentes da resposta do painel nem as regras do semáforo/habitual.
- Nenhum IP ou domínio real em código, testes ou commits (usar 203.0.113.x / 198.51.100.x).
- Textos em pt-BR com acentos. Commits em pt-BR, terminando com `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Backend: `cd backend && .venv/Scripts/python -m pytest -q`. Front: `cd frontend && flutter test` e `flutter analyze`.

## Review Focus
1. Período 30 d (sem histórico anterior): `delta_pct` é `null` e o card mostra "—" sem seta.
2. Primeira semana de syslog (base < 1 dia de dados): `delta_pct` é `null`, nunca um "+900%" inventado.
3. Base com contagem zero: `delta_pct` é `null` (sem divisão por zero).
4. Sem nenhum evento / série vazia: frase "Tudo calmo", cards com 0 e mini-gráfico vazio, sem exceção.
5. Tela estreita (360 px) e nomes de MK longos nos dois temas, sem overflow.

---

### Task 1: Backend — `resumo_estado` (estado e delta_pct por categoria)

**Files:**
- Modify: `backend/nodebeat/painel.py` (nova função e chave em `montar`)
- Test: `backend/tests/test_painel.py`, `backend/tests/test_api_painel.py`

**Interfaces:**
- Produces: `resumo_estado(contagem: dict[str,int], base: dict[str,int], dias_periodo: float, dias_base: float, login_externo_ok: int, vpn_falhas: list[datetime]) -> dict[str, dict]` com `{cat: {"estado": "esperado"|"normal"|"atencao"|"critico", "delta_pct": int|None}}` para as 4 categorias. `montar(...)` devolve a chave `"resumo_estado"` com esse dict.

- [ ] **Step 1: Escrever os testes (RED)** em `test_painel.py` (usar `M`, `falha`, `EV` existentes): `test_resumo_estado_acesso_esperado_e_login_de_fora_critico`; `test_delta_pct_contra_media_dos_7_dias_anteriores` (base de 7 dias: 7 eventos antes do período e 14 no período → `+100`); `test_delta_nulo_sem_base` cobrindo período `30d`, base com menos de 1 dia de dados e base com contagem 0 (`None` nos três); `test_estado_atencao_autenticacao_e_erros_acima_do_habitual` (taxa ≥ `HABITUAL_MIN` e > `HABITUAL_FATOR`× a base); `test_estado_vpn_atencao_com_rajada` (`VPN_FALHAS_N` falhas em 1 h). Em `test_api_painel.py`: `resumo_estado` presente com as 4 chaves e `test_banco_vazio` sem erro.
- [ ] **Step 2: Rodar** `pytest tests/test_painel.py tests/test_api_painel.py -q` → FALHA (chave ausente).
- [ ] **Step 3: Implementar** `resumo_estado` e o preenchimento em `montar`. Regras: acesso `critico` se `login_externo_ok > 0`, senão `esperado`; autenticação e erros `atencao` se `contagem/dias_periodo >= HABITUAL_MIN` e a base é conhecida e `taxa > HABITUAL_FATOR * taxa_base`, senão `normal`; vpn `atencao` se `_rajada(vpn_falhas, VPN_FALHAS_N, 1h)`, senão `normal`. `delta_pct = round((taxa/taxa_base - 1) * 100)` só se `dias_base >= 1` e `base > 0`, senão `None`. Base = eventos em `[inicio - 7 d, inicio)` com as mesmas categorias de `resumo` (exclui `NORMAIS`); `dias_base = min(7, (inicio - primeiro_evento).total_seconds()/86400)` (≤ 0 quando não há histórico, o que cobre o 30 d); `dias_periodo = PERIODOS[periodo] / 24`.
- [ ] **Step 4: Rodar a suíte completa do backend** → tudo passa (279 + novos).
- [ ] **Step 5: Commit** `feat(painel): estado e variação por categoria (resumo_estado)`.

### Task 2: Cliente Flutter — modelo de `resumo_estado`

**Files:**
- Modify: `frontend/lib/api/client.dart` (classe `PainelEventos`; nova `EstadoCategoria`)
- Test: `frontend/test/painel_api_test.dart` (acrescentar `resumo_estado` em `painelJson()`)

**Interfaces:**
- Produces: `class EstadoCategoria { final String estado; final int? deltaPct; }` e `PainelEventos.resumoEstado: Map<String, EstadoCategoria>` (mapa vazio se o campo faltar, para não quebrar respostas antigas).

- [ ] **Step 1: Teste (RED)** `parseia resumo_estado` (acesso `esperado`/+4, vpn `normal`/`null`) e `resposta sem resumo_estado dá mapa vazio`.
- [ ] **Step 2: Rodar** `flutter test test/painel_api_test.dart` → FALHA.
- [ ] **Step 3: Implementar** o parse.
- [ ] **Step 4: Rodar** o teste → PASSA. **Step 5: Commit** `feat(painel): cliente lê resumo_estado`.

### Task 3: Tokens — ciano como cor de marca do NodeBeat

**Files:**
- Modify: `frontend/design-system/tokens.json`; regenerar `frontend/lib/theme/tokens.g.dart` com `dart run tool/gen_tokens.dart` (rodar em `frontend/`)
- Test: `frontend/test/theme_test.dart`

**Interfaces:**
- Produces: `bgBrand` e `actionAccent` = `#22D3EE` (claro e escuro); `fgOnBrand` = `#04222A`; novo token semântico `brandText` (claro `#09768A`, escuro `#5BE0F5`).

- [ ] **Step 1: Teste (RED)** com o helper `contrast` já existente: `fgOnBrand` sobre `bgBrand` ≥ 4,5 e `brandText` sobre `bgSurface` ≥ 4,5, nos dois temas.
- [ ] **Step 2: Rodar** → FALHA (token inexistente).
- [ ] **Step 3: Editar o JSON** (valores acima; `brand-text` como token semântico novo, com `usage`), **gerar** o Dart e conferir que `bgBrand` não é usado fora de `tokens.g.dart` (só `actionAccent`/`fgOnBrand` em `theme.dart`).
- [ ] **Step 4: Rodar** `flutter test` completo → PASSA. **Step 5: Commit** `feat(tema): ciano como cor de marca do NodeBeat`.

### Task 4: Textos e frase de situação (funções puras)

**Files:**
- Create: `frontend/lib/widgets/painel_textos.dart`
- Test: `frontend/test/painel_textos_test.dart`

**Interfaces:**
- Produces: `String fraseSituacao(PainelEventos d)`; `const Map<String,String> explicacaoCategoria` (acesso, autenticacao, vpn, erros — textos do mockup, 2–3 linhas); `String rotuloEstado(String estado)` (`Esperado`/`Normal`/`Atenção`/`Crítico`); `String? notaConcentracao(List<(String,int)> porMk)` (texto "X concentra N% … Confirme se ela precisa ter SSH/Winbox aberto para a internet." quando a primeira MK tem ≥ 25% do total, senão `null`); `String textoDelta(int? deltaPct)` (`↗ +4% vs. média 7 dias`, `↘ −2% …`, `—` quando `null`).
- Consumes: `PainelEventos` da Task 2.

- [ ] **Step 1: Testes (RED)** da frase: login de fora (`estado` acesso `critico`) → começa com "Atenção: houve login de fora aceito."; sem login e com MK vermelha → "Sem invasão detectada, mas 1 MK em vermelho." (plural "2 MKs"); com varredura (total acesso > 0) → "Sem invasão. A rede está sob varredura constante, o que é esperado."; tudo zero → "Tudo calmo." Mais: `textoDelta` (+/−/null), `notaConcentracao` (30% → texto; 20% → `null`; lista vazia → `null`), `rotuloEstado`.
- [ ] **Step 2: Rodar** → FALHA. **Step 3: Implementar** as funções. **Step 4: PASSA.**
- [ ] **Step 5: Commit** `feat(painel): textos, frase de situação e notas`.

### Task 5: Cabeçalho, card de situação e "Atenção agora"

**Files:**
- Create: `frontend/lib/widgets/painel_cards.dart` (`CartaoSituacao`, `PainelAtencao`)
- Modify: `frontend/lib/screens/painel_eventos.dart` (cabeçalho e topo)
- Test: `frontend/test/painel_eventos_test.dart`

**Interfaces:**
- Produces: `CartaoSituacao({required String frase, required int verdes, required int amarelas, required int vermelhas})` — fundo `bgBrand`, texto `fgOnBrand`, textura hachurada (`CustomPaint` diagonal, opacidade do token `hatch`/0,14), sobretítulo `eyebrow` "SITUAÇÃO · ÚLTIMAS 24 H" conforme o período; `PainelAtencao({required List<AtencaoItem> itens, required void Function(String mkId) aoAbrir})` com selo colorido por semáforo e "Tudo certo" quando vazio.

- [ ] **Step 1: Testes (RED)** (claro e escuro): título "Eventos", sobretítulo, frase do card, fichas com 16/2/1 a partir do fixture, "Atenção agora" com o motivo, toque abre `/mk/a`; sem overflow (`t.takeException() == null`) também com largura 360.
- [ ] **Step 2: Rodar** → FALHA. **Step 3: Implementar** (período e MK em pílulas; período ativo `bgInverse`). **Step 4: PASSA. Step 5: Commit** `feat(painel): cabeçalho e card de situação`.

### Task 6: Cards de categoria (selo, variação, mini-gráfico, explicação)

**Files:**
- Modify: `frontend/lib/widgets/painel_cards.dart` (`CartaoCategoria`)
- Test: `frontend/test/painel_eventos_test.dart`

**Interfaces:**
- Produces: `CartaoCategoria({required String categoria, required int total, required EstadoCategoria? estado, required List<PontoSerie> serie, required VoidCallback aoVerDetalhes})`: sobretítulo (`rotuloCategoria`), selo (`rotuloEstado`, cores `info`/`positive`/`warning`/`negative`), número `TradeType.dataLg` (chave `Key('total-$categoria')`), `textoDelta` (acesso sempre `fgSecondary`; demais: alta `negative`, queda `positive`), mini-gráfico `LineChart` sem eixos com `corCategoria`, parágrafo `explicacaoCategoria[categoria]`, link "Ver detalhes →" em `brandText`.
- Consumes: `explicacaoCategoria`, `rotuloEstado`, `textoDelta` (Task 4); `corCategoria`/`rotuloCategoria` (`graficos.dart`).

- [ ] **Step 1: Testes (RED)**: um card por categoria com selo e variação do fixture; `estado` ausente não quebra (sem selo, `—`); série vazia sem exceção; 360 px sem overflow; nos dois temas.
- [ ] **Step 2–4: RED → implementar → PASSA. Step 5: Commit** `feat(painel): cards de categoria que explicam o número`.

### Task 7: Gráficos refinados

**Files:**
- Modify: `frontend/lib/widgets/graficos.dart`; `frontend/test/graficos_test.dart`

**Interfaces:**
- Produces: `GraficoLinha` com área suave sob a linha principal, linhas curvas, tooltip (`LineTouchData`) e pico destacado — `String? rotuloPico` exposto como `static String? picoDe(List<PontoSerie>, List<String>)` (ex.: "03h · 812"); `GraficoBarras` com cor por MK passada em `cor` e barra `radiusPill`; **`GraficoPizza` removido** (o total por categoria já está nos cards) junto com seus testes.

- [ ] **Step 1: Testes (RED)**: `picoDe` (série com pico → "03h · 812", série vazia → `null`); `GraficoBarras` mantém rótulos e valores; `GraficoLinha` com série vazia mostra "Sem eventos no período".
- [ ] **Step 2–4: RED → implementar → PASSA** (`flutter test test/graficos_test.dart`). **Step 5: Commit** `feat(painel): gráficos com área, tooltip e pico`.

### Task 8: Recompor a tela (hero, cards, gráficos, detalhes) e conferir os dois temas

**Files:**
- Modify: `frontend/lib/screens/painel_eventos.dart` (orquestração; remover `_resumo` com a pizza e os blocos antigos redundantes)
- Test: `frontend/test/painel_eventos_test.dart` (ajustar os testes existentes aos novos textos; manter os de erro, 401, filtros e race de pedidos)

**Interfaces:**
- Consumes: `CartaoSituacao`, `PainelAtencao`, `CartaoCategoria` (Tasks 5–6), `GraficoLinha`/`GraficoBarras`, `fraseSituacao`, `notaConcentracao`.

- [ ] **Step 1: Testes (RED)**: ordem na tela (situação → 4 cards → "Ao longo do tempo" + "Por MK" → detalhe do acesso → VPN/Erros → incidentes → mudanças de configuração); nota de concentração aparece com o fixture (Alfa 9 de 12); detalhe do acesso mostra "Quem está tentando entrar", IPs com selo "tentativas" e o selo "Nenhum login de fora aceito" **ou** o aviso vermelho quando há `logins_externos`; `Acesso (hacker)` deixa de existir; erro de API e 401 seguem como antes; 360 e 1100 px, claro e escuro, sem exceção.
- [ ] **Step 2: Rodar** → FALHA. **Step 3: Implementar** a composição (uma coluna abaixo de 900 px).
- [ ] **Step 4: Rodar** `flutter test` completo e `flutter analyze` → tudo passa, sem avisos. **Step 5: Commit** `feat(painel): tela Eventos recomposta no padrão Trade UI`.

### Task 9: Deploy e conferência visual

**Files:** nenhum código; notas em `docs/andamento.local.md` (gitignored).

- [ ] **Step 1:** `backend` completo e `flutter test`/`analyze` verdes; mesclar a branch de trabalho na `main` (`--no-ff`, sem push).
- [ ] **Step 2:** `git archive HEAD | ssh root@<proxmox> "pct exec 119 -- tar -x -C /opt/nodebeat"` e `docker compose -f deploy/compose.yml --env-file deploy/.env up -d --build api web </dev/null` no CT (o build do Flutter web leva ~10–20 min; rodar em segundo plano).
- [ ] **Step 3:** conferir `GET /api/eventos/painel` autenticado traz `resumo_estado` (via script dentro do container da API; nunca ler a senha do Mongo) e o painel abre (HTTP 200).
- [ ] **Step 4:** o dono confere o visual nos dois temas e em tela estreita; ajustes finos viram commits pequenos. Atualizar `docs/andamento.local.md` e a memória do projeto.

# Painel visual dos switches — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dar à aba Switches da tela Eventos indicadores, totalizadores, gráficos de linha, pizza e barras, e projeções de problemas e de capacidade. Para isso, o histórico dos switches passa a ser gravado a cada 5 min.

**Architecture:**
- O worker grava retratos em `unifi_hist`.
- Um módulo puro `backend/nodebeat/switch_painel.py` calcula totais, série, tops e projeções a partir de listas já lidas do Mongo e do Redis.
- A rota `GET /api/eventos/switches` junta tudo.
- No front, dois widgets novos (`GraficoPizza` e `GraficoCapacidade`) e a aba Switches na tela Eventos.

**Tech Stack:** FastAPI, motor/Mongo, redis.asyncio e `statistics.linear_regression`; Flutter web com material_ui e fl_chart.

**Spec:** `docs/superpowers/specs/2026-11-25-switch-painel-design.md` (inclui as "Decisões tomadas após a revisão do builder").

## Global Constraints

- **Testes:**
  - backend com `.venv/Scripts/python -m pytest -q`, a partir de `backend/`;
  - frontend com `/c/src/flutter/bin/flutter test`, e `/c/src/flutter/bin/flutter analyze` limpo, a partir de `frontend/`.
- TDD.
- Amostras com IP e MAC fictícios (192.0.2.x, 02:00:00:…). Nunca IP, MAC, domínio, community ou nome real de cliente no repositório.
- A chave do UniFi nunca vai para log. Em log, só `type(e).__name__`.
- **Constantes:**
  - `LIMITE_INSTAVEL = 30` (projeção/mês) e `MIN_EVENTOS_INSTAVEL = 3`;
  - retrato a cada 300 s; TTL de 400 dias;
  - histórico de capacidade com os últimos 30 dias;
  - projeção só com `dias_historico >= 7`; horizonte de 365 dias; PoE a 80% de `poe_max_w`;
  - série desenhada com no máximo 200 pontos.
- **Baldes da série:** 1h → 5 min; 24h → 1 h; 7d → 6 h; 30d → 1 dia.
- **Projeção dos eventos:** igual a contagem ÷ horas do período × 720, e `null` no período de 1h.
- **Grupos:** `unifi.GRUPOS` (`clientes`, `alertas`, `poe`, `mudancas`), com os rótulos Clientes com fio, Alertas, PoE religado e Mudanças.
- **Visual:**
  - Inviolável/pink: `tokensOf(context)`, `chart1..6`, `Indicador`, `AbasPilula`, `TradeCard`;
  - nada de cor ou tamanho fixo;
  - os dois temas;
  - sem estouro em 360 px;
  - não mexer em `widgets/heartbeat.dart`.
- Commits com o trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- Switch sem PoE (`poe_max_w` null): sem pizza de PoE e com `projecoes.poe = null`, sem divisão por zero (Tasks 2 e 5).
- Menos de 7 dias de histórico: as projeções ficam `null`, e a tela diz "coletando histórico (N dias)" (Tasks 2 e 5).
- Período 1h: `projecao_30d` e `projecao_mes` são `null`, e o indicador mostra "—" (Tasks 2 e 5).
- Período anterior com 0 eventos: a variação não quebra (sem divisão por zero) e não mostra %, como no painel das MKs (Tasks 2 e 5).
- Redis sem `unifi:eq:<id>` (controlador fora): a capacidade usa só o histórico, e `atual` fica null sem erro (Task 3).

---

### Task 1: Retrato do switch a cada 5 min

**Files:**
- Modify: `backend/nodebeat/unifi.py`, `backend/nodebeat/store.py`, `backend/nodebeat/worker.py`
- Test: `backend/tests/test_unifi.py`, `backend/tests/test_worker_unifi.py`

**Interfaces:**
- Produces:
  - `unifi.retrato(eq_id: str, sw: dict, em: datetime) -> dict`, onde `sw` é a saída de `parse_switch`. Devolve `{eq_id, em, poe_usado_w, poe_max_w, clientes, temperatura, cpu, mem, portas_total, portas_em_uso, rx_mbps, tx_mbps, portas: {"<idx>": {up, rx_mbps, tx_mbps, poe_w}}}`. Antes de escrever, leia `_porta()` em unifi.py para os nomes atuais dos campos de porta.
  - `store.garantir_indice_hist(db)` cria `(eq_id, em)` e o TTL `em` de 400 dias. É chamada onde hoje se chama `garantir_indice_unifi`.
  - `store.inserir_retrato(db, doc)`.
  - `store.listar_retratos(db, eq_ids: list[str], desde: datetime) -> list[dict]` faz uma projeção sem `portas`, ordenada por `em`, com `em` aware em UTC.
  - No worker, `run_unifi` grava o retrato de cada switch casado quando `await r.set(f"unifi:hist:{eq_id}", "1", nx=True, ex=300)` é verdadeiro. Um erro gera log `type(e).__name__` e não derruba a rodada.

- [ ] **Step 1: Write failing tests:**
  - `test_retrato_soma_portas_e_conta_em_uso` (3 portas, 2 up, mbps somados, com valores `None` tolerados);
  - `test_retrato_sem_poe` (`poe_max_w` None preservado);
  - `test_run_unifi_grava_retrato_uma_vez_por_5min` (duas rodadas seguidas com o mesmo fakeredis geram 1 documento em `unifi_hist`);
  - `test_listar_retratos_sem_portas`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `.venv/Scripts/python -m pytest -q` → PASS.
- [ ] **Step 5:** Commit `feat(unifi): histórico dos switches a cada 5 min`.

### Task 2: Cálculos do painel (módulo puro)

**Files:**
- Create: `backend/nodebeat/switch_painel.py`
- Test: `backend/tests/test_switch_painel.py`

**Interfaces:**
- Consumes: `unifi.GRUPOS`.
- Produces (funções puras; os eventos são dicts `{tipo, recebido_em (aware UTC), mk_id, campos}`):
  - `totais(atual: list[dict], anterior: list[dict], horas: int, portas_top: list[dict]) -> dict` devolve `{eventos, eventos_anterior, quedas_cliente, quedas_cliente_anterior, portas_instaveis, projecao_30d}`. Com `horas == 1`, `projecao_30d` é None. `portas_instaveis` conta as portas de `portas_top` com `instavel`.
  - `serie(evs, inicio: datetime, periodo: str) -> list[dict]` devolve `[{hora (iso), clientes, alertas, poe, mudancas}]` com todos os baldes, inclusive os zerados. As chaves seguem o formato do `serie_hora` do painel das MKs (`hora`).
  - `portas_top(evs, nomes: dict[str, str], horas: int, n=10) -> list[dict]` devolve `[{switch_id, switch_nome, porta, eventos, projecao_mes, instavel}]`.
    - Conta só `cliente_conectou` e `cliente_desconectou` com `campos.porta`.
    - `instavel` é `eventos >= 3 and projecao_mes is not None and projecao_mes >= 30`.
  - `clientes_top(evs, nomes, n=10) -> list[dict]` devolve `[{cliente, switch_nome, quedas}]` a partir de `cliente_desconectou` com `campos.cliente`.
  - `projecoes(retratos: list[dict], agora: datetime) -> dict` devolve `{dias_historico, poe, temperatura, portas}` com as regras do spec. Usa `statistics.linear_regression` com x em dias. Com menos de 2 pontos ou `dias_historico < 7`, tudo vira None, menos `dias_historico`.
  - `reduzir(retratos, max_pontos=200) -> list[dict]` faz a média por balde igual e devolve `{em, poe_usado_w, clientes, temperatura}`, ignorando os None na média.

- [ ] **Step 1: Write failing tests:**
  - `test_totais_variacao_e_projecao`: 10 eventos em 24h dão `projecao_30d` 300;
  - `test_totais_1h_sem_projecao`;
  - `test_serie_baldes_24h`: 24 baldes, e o evento cai no balde certo;
  - `test_serie_30d_por_dia`;
  - `test_portas_top_ordem_e_instavel`: 3 eventos em 24h é instável (90/mês); 2 eventos não é, mesmo com 60/mês; evento sem porta fica fora;
  - `test_clientes_top`;
  - `test_projecoes_poe_subindo`: com 10 dias de 100→110 W e máximo de 195, `dias_ate_80` é cerca de 46 (de 110 a 156 W, 1 W/dia), e `tendencia_w_dia` é cerca de 1;
  - `test_projecoes_estavel_ou_caindo_da_none`;
  - `test_projecoes_menos_de_7_dias_tudo_none`;
  - `test_projecoes_sem_poe_max`;
  - `test_projecoes_portas_ate_cheio`;
  - `test_reduzir_200`: 1000 retratos viram ≤ 200 pontos, e None é ignorado.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `.venv/Scripts/python -m pytest -q` → PASS.
- [ ] **Step 5:** Commit `feat(painel): cálculos de totais, série, tops e projeções dos switches`.

### Task 3: Rota `GET /api/eventos/switches` ampliada

**Files:**
- Modify: `backend/nodebeat/api.py`, `backend/nodebeat/store.py`
- Test: `backend/tests/test_api_unifi.py`

**Interfaces:**
- Consumes: Task 1 (`listar_retratos`) e Task 2 (todas as funções).
- Produces:
  - **`store.listar_eventos_unifi_periodo(db, desde, ate) -> list[dict]`:**
    - projeção `{tipo, recebido_em, mk_id, campos}`, sem limite;
    - mesmo filtro do `_filtro_unifi`, mais `recebido_em < ate`;
    - `recebido_em` aware em UTC.
    - Ruling: a agregação roda em Python sobre essa projeção, porque o mongomock não suporta `$dateTrunc`. O volume é de centenas por dia. Revisitar se passar de 50 mil eventos por período.
  - **A resposta ganha** `totais`, `serie`, `portas_top`, `clientes_top` e `capacidade`. Os campos `contagens` e `eventos` continuam como hoje.
  - **`capacidade`:**
    - uma entrada por switch cadastrado (`listar_equipamentos(tipo="switch")`) que tenha estado no Redis ou retratos;
    - formato `{switch_id, switch_nome, atual, historico, projecoes}`;
    - **`atual`** sai do Redis `unifi:eq:<id>` e traz `{poe_usado_w, poe_max_w, clientes, temperatura, portas_total, portas_em_uso, poe_por_porta: [{porta, w}] (desc, só w > 0)}`. Sem a chave no Redis, `atual` é None;
    - **`historico`** é `reduzir(retratos dos últimos 30 dias)`;
    - **`projecoes`** é `projecoes(...)` sobre os mesmos retratos.

- [ ] **Step 1: Write failing tests:**
  - `test_switches_traz_totais_serie_tops`: eventos semeados nos períodos atual e anterior; confere `totais.eventos_anterior`, o tamanho da `serie` e `portas_top[0]`;
  - `test_switches_capacidade_com_redis_e_hist`;
  - `test_switches_capacidade_sem_redis_atual_none`;
  - `test_switches_continua_401_sem_login`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `.venv/Scripts/python -m pytest -q` → PASS.
- [ ] **Step 5:** Commit `feat(api): painel dos switches com totais, série, tops e capacidade`.

### Task 4: Front — modelos e gráficos novos

**Files:**
- Modify: `frontend/lib/api/client.dart`, `frontend/lib/widgets/graficos.dart`
- Test: `frontend/test/graficos_test.dart`, `frontend/test/painel_api_test.dart`

**Interfaces:**
- Consumes: o JSON da Task 3.
- Produces:
  - **`EventosSwitches`** ganha `totais` (classe `TotaisSwitches`, com campos int ou int? como no JSON), `serie` (`List<PontoSerie>`, reaproveitado), `portasTop` (`PortaTop {switchNome, porta, eventos, projecaoMes?, instavel}`), `clientesTop` (`ClienteTop {cliente, switchNome, quedas}`) e `capacidade` (`List<CapacidadeSwitch>`).
  - **`CapacidadeSwitch`** tem `switchNome`, `atual?`, `historico` (`List<PontoCapacidade {em, poeW?, clientes?, temperatura?}>`) e `projecoes` (`ProjecoesSwitch {diasHistorico, poeDiasAte80?, poeTendenciaWDia?, temperaturaTendenciaCSemana?, portasDiasAteCheio?, temPoe}`). Um campo ausente no JSON vira null sem erro.
  - **`GraficoPizza({required List<(String, num)> fatias, String? centro})`:**
    - rosca com `PieChart` do fl_chart;
    - cores `chart1..6` em ordem;
    - legenda com valor e %;
    - botão "Ver como tabela", com o mesmo comportamento do `GraficoLinha` (veja como ele faz);
    - com total 0 ou lista vazia, mostra `_Vazio`.
  - **`GraficoCapacidade({required List<(DateTime, double)> pontos, double? limite, double? tendenciaDia, String unidade})`:**
    - linha de 2 px em `chart1`;
    - linha horizontal do `limite`, quando houver;
    - tracejado da projeção (`tendenciaDia`, por 30 dias a partir do último ponto), quando não for null;
    - vazio mostra `_Vazio`.

- [ ] **Step 1: Write failing tests:**
  - `GraficoPizza mostra legenda com %` (fatias 3 e 1 mostram 75% e 25%);
  - `GraficoPizza vazio`;
  - `GraficoPizza tabela`;
  - `GraficoCapacidade desenha com limite`;
  - `GraficoCapacidade vazio`;
  - `EventosSwitches.fromJson completo e sem campos novos` (o JSON antigo continua funcionando).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `flutter test` e `flutter analyze` → PASS e limpo.
- [ ] **Step 5:** Commit `feat(front): gráficos de pizza e de capacidade`.

### Task 5: Front — aba Switches na tela Eventos

**Files:**
- Create: `frontend/lib/screens/painel_switches.dart`
- Modify: `frontend/lib/screens/painel_eventos.dart`
- Test: `frontend/test/painel_switches_test.dart` e ajustes em `frontend/test/painel_eventos_test.dart`

**Interfaces:**
- Consumes: Task 4.
- Produces:
  - **`painel_eventos.dart`:** `AbasPilula` "MKs | Switches" no topo, ao lado das pílulas de período, e o período é compartilhado.
    - A aba MKs mostra o conteúdo de hoje sem o bloco Switches antigo.
    - A aba Switches mostra `PainelSwitches(dados: EventosSwitches, periodo: String)`.
  - **`PainelSwitches`**, em ordem:
    1. **Grade de 4 `Indicador`:**
       - Eventos, com variação;
       - Quedas de cliente, com variação;
       - Portas instáveis, em `warning` quando > 0;
       - Projeção 30 dias, com "—" quando null.
       - A variação mostra sinal e seta (`+40% ↗` / `−12% ↘`) e não mostra % quando o período anterior teve 0, como no painel das MKs.
    2. **Card "Eventos ao longo do tempo"**, com `GraficoLinha` das 4 séries.
    3. **Card "Eventos por grupo"**, com `GraficoPizza`.
    4. **Card "Portas que mais oscilam"**, com `GraficoBarras` (rótulo "switch · Porta N") e uma linha "~N/mês" por porta. As instáveis levam `Selo('Instável', warning)`.
    5. **Card "Clientes que mais caem"**, com `GraficoBarras`.
    6. **Um card "Capacidade — <switch>" por switch:**
       - `GraficoCapacidade` do PoE (com limite `poe_max_w`), só quando `temPoe`;
       - `GraficoCapacidade` de clientes e outro de temperatura;
       - pizza de portas em uso × livres;
       - pizza de PoE por porta (5 maiores + "Outras" + "Livre"), só quando `temPoe`;
       - textos de projeção:
         - "PoE chega a 80% em ~N dias" ou "PoE estável";
         - "Temperatura +X °C/semana";
         - "Portas acabam em ~N dias" ou "Portas estáveis";
       - com `diasHistorico < 7`, um único texto "Coletando histórico (N dias de 7)".
    7. **"Últimos eventos"** recolhido (`ExpansionTile`), com a lista de hoje.
  - **Grade:** 2 colunas a partir de 900 px e 1 coluna abaixo.

- [ ] **Step 1: Write failing tests**, com um `EventosSwitches` montado à mão:
  - `indicadores mostram totais e variação`;
  - `1h mostra — na projeção`;
  - `porta instável tem Selo`;
  - `switch sem PoE não tem pizza de PoE`;
  - `menos de 7 dias mostra coletando histórico`;
  - `abas alternam MKs e Switches`;
  - `360 px sem estouro nos dois temas`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** `flutter test` e `flutter analyze` → PASS e limpo.
- [ ] **Step 5:** Commit `feat(front): aba Switches com gráficos, indicadores e projeções`.

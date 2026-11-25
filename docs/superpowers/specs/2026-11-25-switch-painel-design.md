# Painel visual dos switches (gráficos, indicadores, totalizadores e projeções) — design

Aprovado pelo dono em 2026-11-25: "sim, aprovado, pode seguir. não esquece de incluir gráficos de linha e gráficos pizza".

## Intenção

Hoje o bloco Switches da tela Eventos é só a lista crua do System Log da UniFi. A crítica do dono foi que ela "apenas copiou e colou a lista de eventos, mas não montou nenhum gráfico, e nada visual".

O dono quer:

- gráficos, indicadores, totalizadores e projeções, tão visuais quanto o painel das MKs;
- gráficos de linha e de pizza explicitamente;
- dois tipos de projeção:
  - **de problemas:** quedas e portas instáveis;
  - **de capacidade:** PoE, portas e temperatura, antes de faltar.

O histórico do estado dos switches começa a ser guardado agora, porque hoje só existe o valor do momento, em Redis.

## Objetivos

1. Na tela Eventos, abas **MKs | Switches** no topo. O período (1h, 24h, 7d, 30d) vale para as duas abas. A aba MKs é a tela de hoje, sem mudança.
2. A aba Switches tem:
   - **4 Indicadores** (totalizadores):
     - Eventos no período;
     - Quedas de cliente;
     - Portas instáveis;
     - Projeção 30 dias.
   - **Gráfico de linha:** eventos ao longo do tempo, com uma série por grupo (Clientes com fio, Alertas, PoE religado, Mudanças).
   - **Gráficos de pizza (rosca):**
     - eventos por grupo no período;
     - por switch, portas em uso × livres;
     - por switch com PoE, consumo PoE por porta (as 5 maiores + "Outras" + "Livre", o que sobra até o limite).
   - **Barras:**
     - portas que mais oscilam (top 10), com a projeção mensal de cada uma;
     - clientes que mais caem (top 10).
   - **Capacidade**, um cartão por switch:
     - linha do PoE usado (W) no histórico, com o limite e a projeção tracejada;
     - linhas de clientes e de temperatura;
     - textos de projeção.
   - **Últimos eventos:** a lista de hoje, recolhida, que abre num toque.
3. **Histórico novo:** a cada 5 minutos, um retrato de cada switch casado.

## Não objetivos

- Alertas ou tickets a partir das projeções (o webhook continua desligado).
- Gráficos de Wi-Fi/AP.
- Mudar a aba MKs.

## Anti-objetivos

- **Número inventado:** projeção com menos dados do que o mínimo vira "coletando histórico (N dias)", nunca um valor.
- **Tela lenta:** a rota precisa responder em menos de 1 s com 30 dias de dados.

## Abordagens

1. **Calcular na hora** a partir de `eventos` e da coleção nova `unifi_hist`. **Escolhida:** o volume é pequeno (2 switches; cerca de 580 retratos por dia e centenas de eventos por dia).
2. Pré-agregar em tabelas resumo: descartada, porque é complexidade sem necessidade nesse volume.

## Design

### Histórico (worker)

- Em `run_unifi`, depois de montar `sw` de cada switch casado, grava um retrato em `unifi_hist`, no máximo um a cada 5 minutos por switch.
- O controle é a chave Redis `unifi:hist:<eq_id>` com `SET NX EX 300`. Se a chave existe, não grava.
- **Documento:** `{eq_id, em (UTC), poe_usado_w, poe_max_w, clientes, temperatura, cpu, mem, portas_total, portas_em_uso, rx_mbps, tx_mbps, portas: {"<idx>": {up, rx_mbps, tx_mbps, poe_w}}}`.
  - `portas_em_uso` conta as portas com `up`.
  - `rx_mbps` e `tx_mbps` são a soma das portas.
  - Campos ausentes ficam `null`.
- **Índices:** `(eq_id, em)` e TTL de **400 dias** em `em`, criados junto de `garantir_indice_unifi`.
- Falha ao gravar o histórico só gera log (`type(e).__name__`) e não derruba a rodada.

### API

`GET /api/eventos/switches?periodo=` mantém os campos atuais (`contagens` e `eventos`) e ganha:

- **`totais`:**
  - `{eventos, eventos_anterior, quedas_cliente, quedas_cliente_anterior, portas_instaveis, projecao_30d}`;
  - "anterior" é o período imediatamente antes, de mesmo tamanho;
  - `quedas_cliente` conta os eventos `cliente_desconectou`;
  - `projecao_30d` é o ritmo do período × 30 dias, arredondado. Com período 1h fica `null`, porque a amostra é curta demais.
- **`serie`:** `[{em, clientes, alertas, poe, mudancas}]` com os mesmos baldes da aba MKs: 1h → 5 min; 24h → 1 h; 7d → 6 h; 30d → 1 dia.
- **`portas_top`:** `[{switch_id, switch_nome, porta, eventos, projecao_mes}]`, até 10, contando `cliente_conectou`/`cliente_desconectou` por switch e porta. `projecao_mes` é igual a eventos ÷ horas do período × 720 e fica `null` em 1h.
  - **Porta instável:** `projecao_mes >= 30` (`LIMITE_INSTAVEL = 30`). `totais.portas_instaveis` conta essas portas.
- **`clientes_top`:** `[{cliente, switch_nome, quedas}]`, até 10, a partir de `cliente_desconectou`. O nome vem de `campos.cliente`.
- **`capacidade`:** `[{switch_id, switch_nome, atual, historico, projecoes}]` para cada switch com estado ou histórico.
  - **`atual`:** vem do Redis `unifi:eq:<id>` e traz `poe_usado_w`, `poe_max_w`, `clientes`, `temperatura`, `portas_total`, `portas_em_uso` e `poe_por_porta`, este como `[{porta, w}]` ordenado do maior para o menor.
  - **`historico`:**
    - retratos do período, reduzidos a no máximo 200 pontos pela média por balde;
    - cada ponto tem `{em, poe_usado_w, clientes, temperatura}`;
    - os pontos de capacidade usam sempre os **últimos 30 dias**, qualquer que seja o período da página, porque a capacidade é tendência longa.
  - **`projecoes`:** `{dias_historico, poe, temperatura, portas}`.
    - O cálculo é a regressão linear (`statistics.linear_regression`) dos retratos dos últimos 30 dias.
    - Com `dias_historico < 7`, cada projeção é `null`, e a tela mostra "coletando histórico (N dias)".
    - **`poe`:** `{dias_ate_80: int | null, tendencia_w_dia}`. Fica `null` quando a inclinação é ≤ 0 ou quando passaria de 365 dias, e a tela mostra "estável".
    - **`temperatura`:** `{tendencia_c_semana}`.
    - **`portas`:** `{dias_ate_cheio: int | null}`, sobre `portas_em_uso`, com a mesma regra do `null`.

### Tela (Flutter)

- Visual Inviolável/pink: dois temas, contraste ≥ 4,5:1, cores de série `chart1..6` e nada de cor fixa.
- Reaproveita `GraficoLinha`, `GraficoBarras`, `Indicador`, `AbasPilula` e `TradeCard`.
- **Widget novo `GraficoPizza`:**
  - rosca em `CustomPaint`;
  - legenda com valor e %;
  - "Ver como tabela", como os outros gráficos;
  - sem dados, mostra o `_Vazio` existente.
- **Indicadores:**
  - variação contra o período anterior com sinal e seta (`+40% ↗` / `−12% ↘`), usando a convenção de cor do painel das MKs;
  - Portas instáveis em `warning` quando > 0;
  - Projeção 30d mostra "—" em 1h.
- **Responsivo:** grade de 2 colunas acima de 900 px e 1 coluna abaixo, sem estouro em 360 px.

## Restrições

- TDD.
- Amostras de teste com IPs e MACs fictícios.
- Nenhum IP, domínio ou community real no repositório.
- A chave do UniFi nunca aparece em log.
- `flutter analyze` limpo.
- Não mexer na linha de batimentos.

## Deixado para o builder

- Textos exatos dos rótulos.
- Paleta da pizza (`chart1..6` em ordem).
- Como reduzir o histórico a 200 pontos (média por balde).

## Decisões tomadas após a revisão do builder (chamadas minhas, para o dono conferir)

1. **Porta instável:** além de `projecao_mes >= 30`, a porta precisa de **≥ 3 eventos no período**. Sem esse mínimo, 2 eventos em 24h já marcariam a porta.
2. **Eventos sem `campos.porta`:** não entram em `portas_top`, mas continuam nas contagens e na série.
3. **Onde agregar:**
   - contagens, série e tops rodam no Mongo (`$group`);
   - o histórico é lido com projeção só dos campos usados, sem `portas`;
   - as regressões usam todos os retratos dos 30 dias, e só a série desenhada é reduzida a 200 pontos.
4. **`dias_historico`:** é calculado por switch, como (último `em` − primeiro `em`) em dias.
5. **`dias_ate_80`:** é 80% de `poe_max_w`. Switch sem `poe_max_w` (sem PoE) tem `poe = null` e não ganha a pizza de PoE.
6. **Lugar das pizzas de portas e de PoE:** dentro do cartão de Capacidade de cada switch.
7. **Rótulos das séries:** Clientes com fio, Alertas, PoE religado e Mudanças, os mesmos grupos de hoje.

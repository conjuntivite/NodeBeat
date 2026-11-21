# Painel de eventos: refino visual e explicação em cada card

Data: 2026-11-21. Escopo: pequeno a médio (front Flutter + 2 campos novos no backend). Mockup aprovado: `.superpowers/brainstorm/*/content/eventos-direcao-a.html` e `eventos-cor-marca.html` (opção A, ciano).

## Intenção e porquê
O painel de eventos foi ao ar funcionando, mas "parece alpha": pilha de cartões iguais, sem hierarquia, sem acabamento. E os números não dizem nada sozinhos: "6 mil acessos" não informa se é tentativa de login, se é normal ou se é ataque. O dono quer abrir a tela e **entender em segundos se há motivo para agir**, e saber o que cada card mede.

## Objetivos
1. Cada card diz **o que é** (uma frase) e **se está bom ou ruim** (selo Esperado / Normal / Atenção + variação com seta contra a média).
2. Um **veredito em uma frase** no topo, no card de destaque.
3. Acabamento visual no padrão Trade UI: hierarquia, sobretítulos mono, selos, mini-gráficos, gráficos refinados, textura hachurada, os dois temas.
4. Cor de marca do NodeBeat: **ciano** (`#22D3EE`), no lugar do limão.

## Não objetivos
- Não alterar o Trade UI global (`C:/Users/User/design-systems/trade-ui/`) nem os outros produtos.
- Não mexer nos dados, nas regras do semáforo e do habitual, nem no desempenho (pré-agregação continua como pendência separada).
- Não criar endpoints novos.
- Antiobjetivo: texto longo demais. O parágrafo de cada card cabe em 2 a 3 linhas.

## Decisões (do dono)
- Direção A do mockup: card de situação no topo, KPIs por categoria com explicação, gráficos com subtítulo e nota, bloco de detalhe do acesso.
- Explicação **inline** no card (não escondida em "ⓘ").
- Cor de marca ciano, uma só por tela. Escopo: só NodeBeat (recomendação aceita por padrão).

## Abordagem
Considerei (a) só retocar estilos da tela atual, (b) redesenhar a tela com os dados que já existem, (c) redesenhar e acrescentar ao backend a variação e o selo. Escolhida **(c)**: sem a variação e o selo calculados contra o histórico, o card continuaria sem dizer se o número é bom ou ruim, que era o pedido central.

## Design

### Backend (`painel.py`)
Por categoria em `resumo` passa a existir também (campos novos, os atuais não mudam):
- `delta_pct`: variação da taxa por dia no período contra a média diária dos 7 dias **anteriores ao período**. `null` quando não há base (período 30 d, ou sem histórico).
- `estado`: `"esperado" | "normal" | "atencao" | "critico"`.
  - acesso: `critico` se há login de fora aceito; senão `esperado` (varredura da internet é ruído constante).
  - autenticação: `normal`, ou `atencao` se acima do habitual (mesma regra `HABITUAL_FATOR`/`HABITUAL_MIN` do semáforo).
  - vpn: `normal`; `atencao` se houver rajada de falhas (`VPN_FALHAS_N`).
  - erros: `normal`; `atencao` se acima do habitual.
Resposta ganha `resumo_estado` ao lado de `resumo` para não quebrar o contrato atual.

### Front (Flutter)
- `tokens.g.dart` (cópia do projeto): `bgBrand` = `#22D3EE` nos dois temas; novo `fgOnBrand` = `#04222A` (texto sobre o ciano) e `brandText` para links sobre superfície (claro `#0A7A8F`, escuro `#5BE0F5`). Conferir contraste ≥ 4,5:1 e todos os usos atuais de `bgBrand` (dashboard, login).
- Cabeçalho com sobretítulo mono, título e subtítulo; filtros em pílulas (período ativo invertido).
- Card de situação (`bgBrand`, textura hachurada): frase gerada no front por função pura e testável:
  - login de fora aceito → "Atenção: houve login de fora aceito."
  - senão com MK vermelha → "Sem invasão detectada, mas N MK(s) em vermelho."
  - senão → "Sem invasão. A rede está sob varredura constante, o que é esperado." (se não há varredura: "Tudo calmo.")
  + fichas com a contagem de verdes, amarelas e vermelhas. Ao lado, "Atenção agora" com selos.
- 4 cards de categoria: sobretítulo, selo de estado, número `data-xl`, variação `↗/↘` em `positive`/`negative` (acesso em neutro), mini-gráfico a partir de `serie_hora`, texto "o que é" (mapa estático por categoria) e, no rodapé, "Ver detalhes".
- Gráficos (fl_chart): linha com área suave, tooltip, rótulo do pico; ranking por MK com a nota de interpretação (MK que concentra mais de 25% do total); pizza só se agregar algo, senão sai.
- Bloco de detalhe do acesso: IPs com selo de tentativas, serviço atacado, selo "Nenhum login de fora aceito".
- Textos em português, sem acentos faltando; valores com `tabular-nums`; centavos não se aplicam.

### O que fica a cargo de quem implementar
Textos finais dos parágrafos (seguindo os do mockup), tamanhos exatos, animações discretas, layout em tela estreita (1 coluna abaixo de 900 px).

## Testes
- Backend: `delta_pct` (com e sem base) e `estado` por categoria (RED→GREEN), incluindo login de fora → `critico`.
- Front: função da frase de situação; cards mostram selo, variação e texto; temas claro e escuro sem overflow; contraste dos novos tokens.
- Conferência visual final nos dois temas pelo dono.

## Riscos
- Conferido no código: `bgBrand` não é usado fora de `tokens.g.dart`; `actionAccent`/`fgOnBrand` só entram no `colorScheme.secondary` do tema. A troca para ciano, na prática, só aparece na tela Eventos (dashboard e login não mudam).
- Ciano é próximo do azul de informação: manter `info` como está e conferir os selos "Esperado" ao lado da marca.

# Painel de eventos (aba de monitoramento)

Data: 2026-11-19. Projeto médio. Aprovado pelo usuário: os 4 blocos pedidos e as 6 recomendações, tudo na primeira versão.

## Por quê
O NodeBeat já recebe eventos (syslog) das 19 MKs, mas só se vê por MK, no cartão Eventos do detalhe. O usuário quer uma tela
central para, ao abri-la, ver: erros separados por categoria, tentativas de acesso (hacker), erros de VPN e de
autenticação, e "todos os erros importantes". Pedido adicional: ficar um passo à frente do cliente, vendo o problema
antes de ele reclamar.

Dados hoje (30 dias, 19 MKs): 2033 `login_falha`, 1529 `outro/warning` (a maioria `late collision / duplex mismatch`),
508 `pppoe` com erro, 39 `ipsec`, 14+4 `erro`, 55 logout, 36 login, 139 config.

## Objetivos
- Aba nova "Eventos" na página inicial, com filtro de período (24 h, 7 dias, 30 dias) e filtro por MK.
- Faixa "Atenção agora" no topo: semáforo por MK (verde, amarelo, vermelho) com o motivo.
- Resumo: pizza por categoria, barras por MK, linha de volume por hora.
- Quatro blocos: Acesso (hacker), Autenticação, VPN, Erros importantes.
- Seis recomendações: (1) semáforo e MK em silêncio, (2) login bem-sucedido de fora e usuário novo, (3) instabilidade
  (oscilação de enlace e túnel, queda em massa de PPPoE, colisão/duplex, reboot repetido), (4) incidente
  correlacionado entre MKs, (5) linha do tempo de mudanças de configuração, (6) comparação com o habitual da MK.

## Não objetivos
- Alertas por webhook/ticket (ficam para depois). CPU, memória, temperatura (não vêm por syslog). Checagem de serviços
  expostos (etapa de segurança). Editar ou apagar eventos.

## Abordagens
1. **Escolhida: categorias calculadas na consulta; totais no backend; gráficos com `fl_chart`.** Funciona com os 30 dias
   já gravados. O volume é pequeno (milhares de eventos), então um endpoint lê o período e agrega em Python.
2. Novos tipos na gravação (o classificador marca `acesso_externo`, `vpn_erro` etc.). Descartada: só vale para eventos
   futuros e prende a regra no momento da gravação.
3. Gráficos desenhados à mão (`CustomPaint`). Descartada: três tipos de gráfico com tooltip dão mais trabalho que a
   dependência.

## Design
**Backend** (`backend/nodebeat/painel.py`, função pura + rota `GET /api/eventos/painel?periodo=24h|7d|30d&mk=<id>`).
`painel.py` recebe a lista de eventos (já gravados), os cadastros das MKs, `sede_redes`, os IPs públicos da sede, a hora
atual, e devolve um dicionário. `store.py` ganha `listar_eventos_periodo(db, desde, mk_id|None)`.

Categoria de cada evento (`categoria(ev, ctx)`):
- `acesso_hacker`: `login_falha` cujo IP de origem é público e não está nos IPs públicos da sede (nem em `sede_redes`).
  Técnico que erra senha de fora conta aqui (decisão do usuário).
- `autenticacao`: `login_falha` de IP privado (LAN da MK ou sede) e `login` bem-sucedido.
- `vpn`: `ipsec` (falhas de fase 1 e 2 separadas pelo texto da mensagem).
- `erros`: `pppoe` com severidade erro, `interface` down, `reboot`, `erro`, e `link_fisico` (mensagem com
  `collision` ou `duplex mismatch`, hoje `outro`).
- demais: ignorados no painel (exceto `config`, usado na linha do tempo).

Resposta: `{periodo, resumo{categoria: n}, por_mk[{mk_id, nome, semaforo, motivos[], contagens}], serie_hora[{hora,
acesso, autenticacao, vpn, erros}], blocos{acesso{top_ips, por_via, por_mk}, autenticacao{...}, vpn{...},
erros{...}}, atencao[], incidentes[], config[]}`.

Regras das recomendações (limites são minha escolha e ficam como constantes no `painel.py`):
- **Semáforo.** Vermelho: login bem-sucedido de IP público fora da sede, ou ≥ 2 reboots em 24 h, ou oscilação.
  Amarelo: MK sem nenhum evento há mais de 24 h (silêncio), usuário novo, ou acima do habitual. Verde: o resto.
- **Login de fora.** `login` com IP de origem público fora da sede e `usuario != monitor`. Destaca também IP que errou e
  depois acertou.
- **Oscilação.** ≥ 3 `interface down` da mesma interface em 1 h, ou ≥ 3 eventos `ipsec` de falha em 1 h na mesma MK.
  Queda em massa de PPPoE: ≥ 10 eventos pppoe de erro da mesma MK em 15 min. Colisão/duplex: contagem por interface.
- **Incidente correlacionado.** Janela de 15 min em que ≥ 3 MKs tiveram o mesmo sintoma (interface, ipsec, pppoe,
  reboot): vira um item único em `incidentes`.
- **Mudanças.** Eventos `config` com usuário, objeto e ação. Marca "fora do horário" (antes das 7 h ou depois das 19 h,
  America/Sao_Paulo) e "usuário novo" (não visto nos 30 dias anteriores naquela MK).
- **Habitual.** Média diária de eventos importantes da MK nos 7 dias anteriores; marca "acima do habitual" quando as
  últimas 24 h passam de 3 vezes a média e de 20 eventos.

**Frontend.** `frontend/lib/screens/painel_eventos.dart` (rota `['eventos']` no `main.dart`, botão na barra do
dashboard ao lado do "Preparar MK"), `frontend/lib/widgets/graficos.dart` (pizza, barras, linha com `fl_chart`),
modelos em `frontend/lib/api/`. Trade UI: tokens semânticos, temas claro e escuro, uma cor de marca por tela; as
cores de categoria usam `negative`, `warning`, `info` e `risk`, nunca só cor (rótulo e ícone junto, contraste ≥ 4.5:1).
Clicar numa MK do semáforo abre o detalhe dela.

## Decisões minhas (para conferir)
- Limites numéricos acima e o horário comercial 7 h a 19 h.
- IP privado que erra login conta como autenticação, não como hacker.
- Silêncio considera 24 h (MK pequena pode ficar quieta; ajustável).
- Agregação em Python lendo o período todo. Teto: dezenas de milhares de eventos; depois disso, mover para pipeline do
  Mongo.

## Testes
Backend: pytest da função `categoria` e das regras (semáforo, oscilação, incidente, habitual, fora do horário) com
eventos montados à mão, e da rota com autenticação. Frontend: teste de widget com resposta de exemplo (tela mostra
semáforo, blocos e filtro) e `flutter analyze` limpo.

# Paletas do mapa de ataques (TV)

Data: 2026-11-26 · Status: aprovado pelo dono (maquete com 8 paletas aprovada)

## Intenção
O pink do mapa está ruim de ler. Em vez de deixar o sistema todo personalizável, só a TV (`#/tv`) ganha a escolha de **paletas fixas** do mapa; nenhuma usa pink. O resto do sistema não muda.

## Decisões do dono
- 8 paletas fixas (sem cor livre), escolhidas na própria TV; aprovadas na maquete.
- Sem pink no mapa, inclusive no popup de Acesso.

## Paletas (valores aprovados)
Cada uma: fundo, terra, borda, destino/texto (ponto da MK e rótulos sobre o mapa) e 6 cores de serviço na ordem SSH, TELNET, FTP, API, WINBOX, outros (WEB…). Login aceito: sempre `#EF4444`.

| id | nome | fundo | terra | borda | destino/texto | SSH | TELNET | FTP | API | WINBOX | outros |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ardosia | Ardósia | #0F1620 | #2A3544 | #3A4757 | #F3F4F6 | #60A5FA | #FB923C | #34D399 | #FBBF24 | #A78BFA | #94A3B8 |
| cinza | Cinza claro | #E6EAF0 | #9AA5B4 | #7D8999 | #111827 | #2563EB | #EA580C | #059669 | #B45309 | #7C3AED | #475569 |
| noite | Noite | #05070B | #1A222D | #263140 | #FFFFFF | #22D3EE | #F97316 | #4ADE80 | #FACC15 | #C084FC | #9CA3AF |
| oceano | Oceano | #0A2540 | #1D4268 | #2C5A87 | #F8FAFC | #7DD3FC | #FDBA74 | #86EFAC | #FDE047 | #D8B4FE | #CBD5E1 |
| grafite | Grafite | #18181B | #3F3F46 | #52525B | #FAFAFA | #38BDF8 | #FB923C | #4ADE80 | #FACC15 | #A78BFA | #A1A1AA |
| papel | Papel | #F7F7F4 | #D6D3CB | #B8B4AA | #1C1917 | #1D4ED8 | #C2410C | #047857 | #A16207 | #6D28D9 | #57534E |
| floresta | Floresta | #0C1A14 | #1F3A2C | #2D5240 | #F0FDF4 | #7DD3FC | #FDBA74 | #BEF264 | #FDE047 | #C4B5FD | #A8A29E |
| alto | Alto contraste | #000000 | #3A3A3A | #6B6B6B | #FFFFFF | #00B7FF | #FF8A00 | #00E676 | #FFEA00 | #B388FF | #FFFFFF |

## Funcionamento
- TV: botão "Paleta do mapa" no cabeçalho, ao lado do claro/escuro, abre as 8 opções (miniatura com fundo, terra e 3 cores de serviço + nome; a atual marcada). Escolha salva no navegador (localStorage `nodebeat_tv_paleta`, valor = id). Padrão: `ardosia`. Id desconhecido → padrão.
- A paleta pinta a área do mapa inteira (fundo, terra, borda, ponto de destino, rótulos e legenda sobre o mapa) e as bolinhas de serviço da lista ao vivo e da coluna de tops. O claro/escuro continua valendo para o resto da página.
- Popup de Acesso: sem escolha; usa `cinza` no tema claro e `ardosia` no escuro.

## Abordagens
Personalização do sistema todo por usuário/empresa (descartada pelo dono); cores fixas sem escolha (descartada: dono quer escolher na TV); **paletas fixas só no mapa (escolhida)**: legível por construção, sem editor de cor.

## Fora do escopo
Resto do sistema (pink continua nos demais gráficos), cor livre, paleta por usuário.

## Decisão minha (corrigível)
As paletas ficam como dados num arquivo Dart (`lib/ataques/paletas.dart`), não como tokens do design system: são 8 conjuntos fechados só do mapa, exceção documentada à regra de tokens.

## Revisão 2026-11-26 — a paleta pinta a TV inteira (aprovada na maquete)
O dono esclareceu: a paleta é da **tela toda da TV**, não só do mapa. Decisões aprovadas:
- A paleta vira o tema da TV: fundo da página = `fundo`; cabeçalho, lista ao vivo e coluna de tops = `painel`; bordas = `bordaPainel`; textos = `texto` e `textoSec`.
- Sai o botão claro/escuro da TV (cada paleta já é clara ou escura); fica só o botão de paleta. O tema claro/escuro salvo da TV deixa de ser usado.
- Selos e alertas (ao vivo, Tentativa, Acesso aceito, faixas de login aceito) usam os tokens de status do tema claro (paletas claras) ou escuro (paletas escuras).
- Nenhum pink na TV: realce de menu, foco e cor de ação usam `vias[0]` da paleta. O ícone do NodeBeat continua (logo), na versão clara/escura conforme a paleta.
- Resto do sistema e popup de Acesso inalterados.

| id | clara/escura | painel | bordaPainel | textoSec |
|---|---|---|---|---|
| ardosia | escura | #151E2B | #243041 | #A9B4C2 |
| cinza | clara | #F4F6F9 | #C9D1DC | #4B5563 |
| noite | escura | #0C1118 | #1C2430 | #A3ACB9 |
| oceano | escura | #0F2E4D | #1E4468 | #B6C6D8 |
| grafite | escura | #202024 | #34343A | #A1A1AA |
| papel | clara | #FFFFFF | #E2DFD8 | #57534E |
| floresta | escura | #11231B | #22392D | #A7C4B3 |
| alto | escura | #0A0A0A | #4A4A4A | #D4D4D4 |

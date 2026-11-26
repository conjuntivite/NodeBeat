# Mapa de ataques ao vivo (popup de Acesso + aba da TV do NOC)

Data: 2026-11-25 · Status: aguardando aprovação (revisado)

## Intenção

O NOC quer **uma TV com um mapa-múndi mostrando, ao vivo, de onde vêm as tentativas de login nas MKs**, no estilo do FortiGuard Threat Map (https://fortiguard.fortinet.com/threat-map). Motivo: enxergar na hora quando começa uma onda de força bruta, como a de 2026-11-25 às 04h no FEAT COLIVING, que derrubou o acesso do NodeBeat por horas.

Hoje o card **Acesso** da tela Eventos abre um popup ("Quem está tentando entrar") com o top 10 de IPs e as barras por serviço (`frontend/lib/screens/painel_eventos.dart`, `_abrirDetalhe` / `_detalheAcesso`). O popup tem largura máxima de 760 px e não tem mapa.

## Objetivos

1. **Popup de Acesso maior e com destaque:** ocupa quase a tela inteira, com o mapa ao vivo em cima e, abaixo, o conteúdo de hoje (top IPs, serviço atacado e a pílula de login de fora aceito).
2. **Atalho "Abrir em tela cheia"** no popup, que abre uma **nova aba do navegador** com uma rota só do mapa, sem barra lateral e sem cabeçalho do app, para deixar na TV.
3. **Linha animada por ataque:** uma curva sai do ponto de origem (país do IP) e "viaja" até o destino (a MK). Quando chega, a linha inteira fica visível, da origem ao destino, e depois some aos poucos.
4. **Ao vivo:** as tentativas que chegam pelo syslog aparecem no mapa com atraso de até ~5 s.
5. **Rodapé da TV:** top 24 h (países/IPs de origem e serviço atacado) e o indicador "ao vivo".

## Fora do escopo

- Bloquear IPs (fica para a fase de segurança; ver memória `nodebeat-forca-bruta-login-recusado`).
- Perfil "só leitura" ou link com chave para a TV: o dono escolheu **um usuário comum só para a TV**, criado pelo painel de usuários, e refazer o login quando a sessão de 8 h expirar. Nenhuma mudança de autenticação.
- Localização por cidade, ASN ou provedor.
- Posição real de cada MK no mapa.

## O que tornaria isso um fracasso

- TV parada ou congelada sem ninguém perceber: a tela precisa mostrar quando o feed parou ("sem dados há X min") e voltar sozinha quando a rede voltar.
- A tela virar um borrão nos picos (~700/h numa MK) ou travar o navegador da TV depois de horas aberta (vazamento de animações/memória).
- Enviar IPs ou dados das MKs para serviços externos de geolocalização.
- Mostrar o IP público das MKs na TV.

## Restrições

- Front em Flutter web; o design system do NodeBeat é o "Inviolável + pink" (`frontend/design-system/`, `lib/widgets/shell.dart`), com os dois temas. A aba da TV usa o tema escuro fixo.
- Não mexer na linha de batimentos (`widgets/heartbeat.dart`).
- Sem biblioteca nova de mapa no Flutter: o mapa e a animação são desenhados com `CustomPainter` + `AnimationController`.
- Backend Python (FastAPI + Mongo + Redis). Eventos na coleção `eventos` (TTL 30 dias), gravados pelo serviço `syslog` em lotes de ~1 s.
- "Externo" segue a regra já existente em `backend/nodebeat/painel.py` (`categoria` → `("acesso", "falha_externa")` e `("acesso", "login_externo_ok")`, com `NODEBEAT_SEDE_REDES` / IPs da sede).
- Deploy pelo procedimento de sempre no CT 119.

## Abordagens consideradas

| | Como funciona | Prós | Contras |
|---|---|---|---|
| **A. Consulta a cada ~5 s (escolhida)** | A tela pede "o que chegou desde o cursor X"; o servidor devolve as tentativas novas já com país e MK | Usa o login e o caminho que já existem; funciona pelo Cloudflare; uma falha de rede se recupera na próxima consulta | Atraso de até ~5 s |
| B. Stream do servidor (SSE) | O syslog avisa a API (pub/sub) e a API empurra para a tela | Instantâneo | Peça nova; conexão longa pelo nginx e pelo Cloudflare; reconexão |
| C. WebSocket | Igual ao B | Instantâneo | Ainda mais código que o B |

O dono escolheu **A**.

Sobre o conteúdo das linhas, foram consideradas duas opções: **ao vivo** (escolhida) e **replay em loop do top do período** (descartada: a TV mostraria sempre o mesmo desenho e não reagiria a uma onda nova).

## Decisões do dono

- Ao vivo, com o top 24 h no rodapé.
- Popup maior + atalho para uma nova aba só com o mapa.
- Consulta a cada ~5 s (abordagem A).
- Aviso de login de fora aceito **por tela** (item 13).
- Usuário próprio da TV, comum (não admin), criado pelo painel de usuários; relogar a cada 8 h é aceito. **Risco registrado:** hoje qualquer usuário logado pode reiniciar MK (`api.py`, `POST /mks/{id}/reiniciar`). Fica para a fase de segurança.

## Desenho (decisões minhas, corrigíveis)

### Backend

1. **Geolocalização offline por país.** Base **DB-IP "IP to Country Lite"** (CSV, CC-BY 4.0, atualizada todo mês) baixada para dentro da imagem/volume do servidor. Busca em memória com `bisect` sobre as faixas ordenadas, sem dependência nova. Uma tabela estática de **centroide por país** (ISO-2 → lat/lon, ~250 linhas) dá o ponto de origem. IP sem país → ponto "desconhecido" (não desenha a linha, mas conta no rodapé). Atribuição "IP data by DB-IP" visível na aba da TV (exigência da licença). Atualização da base: manual, junto com um deploy (anotar no README do deploy).
2. **Endpoint do feed:** `GET /api/eventos/ataques?desde=<cursor>` (usuário logado). Devolve:
   - `cursor`: o `_id` do último evento considerado (ObjectId é crescente na inserção; o syslog grava em ordem).
   - `ataques`: tentativas externas novas (`falha_externa` e `login_externo_ok`) **agrupadas por (IP, MK)** dentro da resposta: `{ip, pais, lat, lon, mk_nome, via, n, sucesso}`. Sem IP público da MK.
   - Primeira chamada sem `desde`: devolve só o cursor atual e nenhum ataque (a tela começa "do agora").
   - Limite de segurança: no máximo N grupos por resposta (ex.: 200, mais recentes); o resto entra só na contagem.
3. **Rodapé 24 h:** reaproveitar o bloco `acesso` que `painel.montar` já calcula (`top_ips`, `por_via`, `logins_externos`), acrescentando o país em cada `top_ips` e um `top_paises`. A TV pede isso a cada ~60 s, não a cada 5 s.

### Frontend

4. **Mapa:** contorno dos continentes do **Natural Earth 110m** (domínio público), pré-projetado em equiretangular e salvo como asset compacto (lista de polígonos simplificados, alvo < 150 KB). Desenhado uma vez num `CustomPainter` em cache (camada estática), com as linhas em outra camada.
5. **Destino:** um ponto fixo, o oeste de SC (região das MKs), constante no front. O rótulo da linha mostra o nome da MK. Todas as linhas convergem nesse ponto, como no FortiGuard.
6. **Animação:** arco quadrático (curva de Bézier) da origem ao destino, com altura proporcional à distância. Fases: (a) a cabeça viaja da origem ao destino (~1,5 s), deixando o traço; (b) a linha inteira fica visível (~2 s) com um "pulso" no destino; (c) some aos poucos (~1 s). Cor por serviço (SSH, telnet, FTP, API, winbox), seguindo os tokens `chart-*`. **Login de fora aceito** (alguém de fora da sede conseguiu logar numa MK) usa a cor `negative` e linha mais grossa, e gera um aviso fixo (ver item 13).
7. **Ritmo:** os grupos recebidos em cada consulta são distribuídos ao longo dos ~5 s seguintes. Teto de linhas simultâneas (ex.: 60); acima disso, descarta as mais antigas da fila e mostra o "+N" no contador.
8. **Popup de Acesso:** passa a ocupar ~92% da largura e da altura da janela. Mapa ao vivo em cima e o conteúdo atual embaixo (rolável). Botão "Abrir em tela cheia" ao lado do fechar → `window.open('/eventos/mapa', '_blank')`.
9. **Aba da TV** (`/eventos/mapa`): rota própria fora da casca (`AppShell`), tema escuro fixo, mapa ocupando a tela. Cabeçalho mínimo: logo do NodeBeat, "Ataques às MKs", relógio e indicador "● ao vivo" (fica âmbar com "sem dados há X min" se as consultas falharem por mais de 30 s). Rodapé: top países, top IPs e barras por serviço (24 h). Se a sessão expirar (401), mostra o login e volta ao mapa depois de entrar.
10. **Higiene para rodar dias seguidos:** sem acumular objetos (fila com teto, `AnimationController` reaproveitado ou descartado), consulta pausada quando a aba fica oculta e retomada ao voltar.

11. **Escopo do feed** *(minha decisão)*: só MKs, com a mesma regra do card Acesso (`painel.montar` ignora `mk_id = "eq:*"`). Firewall e switch ficam de fora até mandarem login por syslog de forma útil.
12. **Filtros da tela Eventos** *(minha decisão)*: o mapa ao vivo do popup mostra sempre **todas as MKs, ao vivo**, com essa legenda escrita sobre o mapa. O conteúdo abaixo continua seguindo o período e o filtro de MK da tela. Sem parâmetro `mk` no feed.

13. **Aviso de login de fora aceito (decisão do dono: por tela):** faixa fixa no topo do mapa (popup e TV) com MK, usuário, IP, país, serviço e hora, e um botão "Ciente". Ao abrir/recarregar, mostra os logins aceitos das últimas 24 h (de `logins_externos` do rodapé); os novos entram pelo feed ao vivo. "Ciente" esconde só naquela aba (memória da página; ao recarregar, o que ainda estiver nas 24 h volta). Nada novo no servidor.

### Testes

- Backend: busca de país (faixas na borda, IP fora da base, IP privado); agrupamento e cursor do feed (sem duplicar e sem perder entre chamadas); só externos entram.
- Front: geometria do arco (pontos inicial/final e projeção equiretangular); fila/ritmo com teto.

## Fica para quem constrói

- Tempos exatos da animação, espessuras e brilho, dentro dos tokens.
- Formato do asset do mapa e o nível de simplificação.
- Valores de N (grupos por resposta) e do teto de linhas, a partir de uma medição com o volume real.

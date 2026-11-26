# TV de ataques — lista ao vivo, coluna de tops com bandeiras e tema claro/escuro

Data: 2026-11-26 · Status: aprovado pelo dono · Referência visual: FortiGuard Threat Map (print3)

## Intenção

A aba da TV (`#/eventos/mapa`) é para o NOC acompanhar os ataques às MKs. O dono quer o layout do FortiGuard: mapa no centro, **lista ao vivo dos ataques embaixo**, **coluna à direita com os tops das últimas 24 h**, **bandeiras dos países** e **escolha de tema claro/escuro na própria TV**.

## O que muda (só front, só a aba da TV)

1. **Lista ao vivo embaixo do mapa:** as 8 tentativas mais recentes do feed, a mais nova no topo. Cada linha: hora · serviço (SSH, TELNET…) · `×N` quando o grupo tem mais de uma · bandeira + país + IP de origem · → nome da MK · selo "Tentativa" (neutro) ou "Acesso aceito" (`negative`).
2. **Coluna à direita (24 h, do painel que a TV já lê a cada 60 s):** Top tentativas (IPs, com bandeira), Top países (com bandeira), Top tipos de acesso (barras por serviço). Substitui o rodapé atual.
3. **Bandeiras:** imagens PNG pequenas dentro do app (`assets/bandeiras/<cc>.png`, flagcdn, domínio público), uma por país da base de países. País desconhecido ou sem imagem: espaço vazio do mesmo tamanho. Sem emoji (a fonte não tem e o build não baixa fonte de fora — mesmo motivo do "●").
4. **Tema:** a TV deixa de forçar o escuro e segue o tema do usuário logado; o botão claro/escuro (`ThemeToggle`, o mesmo das outras telas) fica no cabeçalho da TV e grava a escolha no usuário da TV.

## Fora do escopo

Popup de Acesso (continua como está); servidor (o feed já traz `pais` = código do país; `top_ips` e `top_paises` também); filtro por região como no FortiGuard.

## Decisões minhas (corrigíveis)

- 8 linhas na lista ao vivo; coluna lateral com 360 px de largura e 5 itens por top.
- Bandeiras de 20×15 px no texto, PNG largura 40 (nítido em TV).

## Abordagens

Bandeira por emoji (descartado: quadrado no lugar, como o "●"); por pacote SVG (descartado: dependência nova); **PNG em asset (escolhido)**: sem dependência, offline.

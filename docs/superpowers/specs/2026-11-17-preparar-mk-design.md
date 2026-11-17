# Preparar MK — design (curto)

## Intenção
Quem coloca uma MK nova no NodeBeat hoje precisa achar `deploy/routeros-monitor-user.rsc` no repositório e
preencher 4 valores à mão. Queremos uma página no painel com o passo a passo e **um script que se cola no
terminal da MK (Winbox → New Terminal) sem preencher nada**: ele descobre sozinho o que é da MK e já vem com o
que é do servidor.

## Abordagens
- **A) Página única "Preparar MK" no menu** — escolhida. Serve MK nova e já cadastrada; nada salvo.
- B) Script dentro do cadastro da MK — descartada: só funciona ao cadastrar (na edição a senha não volta).
- Script de coleta + acesso do Claude à MK — descartado: o próprio script descobre os dados, sem abrir acesso
  extra e sem os dados saírem da MK.

## Decidido
- **A MK descobre:** versão (`/system resource`) → `address=` (< 7.24) ou `available-from=` (≥ 7.24);
  interface WAN = da rota padrão ativa (PPPoE e IP fixo); ao fim imprime o IP do túnel (IP da LAN coberto pela
  política IPsec) e o IP público da WAN, para o cadastro no painel.
- **Falha na descoberta** (sem rota padrão, mais de uma WAN ativa…): o script para **antes de alterar qualquer
  coisa** e diz o motivo.
- **O servidor fornece:** `NODEBEAT_IP_ORIGEM` (IP com que o NodeBeat chega na MK, hoje o do túnel) e
  `NODEBEAT_IP_PUBLICO_SEDE` (regra de ICMP), via `GET /api/preparar-mk` (logado). Sem elas a página avisa o que
  falta no `.env`. Valores reais só no `.env` do CT, nunca no repositório.
- **Senha do `monitor`:** gerada no navegador (20 caracteres, só letras e números: o script não aceita `$`,
  aspas nem acentos); nunca vai ao servidor. A página mostra a senha para o cadastro.
- **Política do grupo:** `read,api,reboot` e nada mais.
- **Página:** script montado no navegador + Copiar; conferência (`/user print`, `/ip service print`);
  cadastro no painel; seção "MK já cadastrada: liberar o reinício" (1 linha); seção "Desfazer tudo".
  Ícone no topo do painel ao lado de Faixas. Trade UI, temas claro e escuro.
- **Fonte única do script:** a página. `deploy/routeros-monitor-user.rsc` sai do repositório; `deploy/README.md`
  aponta para a página.

## Fora
Script gerado no cadastro; salvar valores; aplicar o script na MK pelo sistema.

## Para quem constrói
- Comandos de descoberta precisam funcionar na 6.49 e na 7.24 (`gateway-status` na v6 × `immediate-gw` na v7);
  validar com comandos só de leitura na MK v7 de teste (SSH read-only) antes de fechar.
- Script idempotente o bastante para re-rodar: remover/atualizar o que já existe (certificados, grupo, usuário,
  regra) em vez de falhar no meio.

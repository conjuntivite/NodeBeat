# NodeBeat: equipamentos por tipo (abas) e o Switch como primeiro tipo

Data: 2026-11-24. Status: aguardando aprovação do dono.

## Intenção (palavras do dono)

"Preparar o NodeBeat para monitorar qualquer equipamento, software ou hardware que tenha um IP e logs de eventos." Hoje usam o Zabbix e o maior problema é "a dificuldade de usar a plataforma, existem milhões de opções e abas". O NodeBeat deve "entregar o que o Zabbix entrega, mas ser mil vezes mais fácil de configurar".

Pedido concreto desta etapa: abas **MK**, **Switch** e **Firewall**; dentro de um switch, "um desenho do switch e as portas, verde para as portas on e outra cor para as down", inspirado nos layouts da Ubiquiti (UniFi). As **MKs também** ganham o desenho das portas com link on/down.

## Regra de decisão

Configurar o mínimo. Se uma tela ou opção lembra o Zabbix (templates, itens, triggers editáveis, dezenas de campos), está errado. Cadastrar um equipamento = nome, IP, tipo, local; o resto vem do tipo.

## Objetivos

1. **Base genérica de equipamento**: coleção nova `equipamentos` e um contrato de "tipo" no código, usado pelos tipos novos.
2. **Switch como primeiro tipo** nessa base:
   - switches gerenciáveis já descobertos por SNMP dentro dos condomínios aparecem sozinhos na aba Switch;
   - cadastro manual só para o que nenhuma MK enxerga (ex.: switch da sede);
   - estado (no ar / offline), desenho frontal com o estado de cada porta, eventos do syslog pelo IP de origem, ticket no TiDesk quando o switch cai ou quando cai uma **porta de uplink**.
3. **Abas no topo do painel**: MK (o dashboard atual), Switch, Firewall.
4. **Desenho frontal das portas também na tela da MK**, com os dados que o worker já coleta (`portas_link`).

## Não objetivos (desta etapa)

- **Firewall**: a aba aparece, mas o tipo vem num projeto seguinte, quando soubermos marca/modelo. Até lá a aba mostra "nenhum firewall cadastrado" sem botão de cadastro funcional (decisão do builder: esconder o botão ou mostrar "em breve").
- Migrar a MK para a coleção `equipamentos` (projeto posterior, depois que o contrato estiver provado com o Switch).
- Modelos/templates editáveis pela tela (o dono escolheu tipos no código).
- Gráficos de tráfego por porta, CPU do switch, SNMP v3, escrita no switch.
- Desenho específico por modelo de aparelho.

## Anti-objetivos

- Barulho de tickets: porta comum que cai (alguém desligou uma câmera) **não** abre ticket. Lembrar dos 70 tickets da oscilação.
- Telas de configuração cheias de opções.
- Quebrar o monitoramento das 19 MKs em produção.

## Abordagens consideradas

1. **Migrar tudo agora** (`mks` vira `equipamentos` com `tipo: "mk"`): um caminho só, mas mexe em quase todo arquivo com produção abrindo tickets. Descartada pelo risco.
2. **Construir ao lado e trazer a MK depois** (escolhida pelo dono): `equipamentos` recebe os tipos novos, a MK fica como está, as abas juntam as duas fontes. Dois caminhos temporários, produção intocada, contrato validado com o Switch.
3. **Modelo editável pela tela** (estilo template do Zabbix): descartada pelo dono; muito trabalho e vai contra a regra de simplicidade.

Estilo do desenho: o dono escolheu **A, frente do aparelho estilo UniFi** (contra B, grade numerada). Mockup: `.superpowers/brainstorm/1766-1795524655/content/portas.html` (local, ignorado pelo git).

Alerta de porta: o dono escolheu **ticket só para porta de uplink** (contra "só na tela" e "qualquer porta"). Porta com switch burro, ou seja, com 3 ou mais aparelhos vigiados atrás, conta como uplink.

## Como funciona hoje (o que esta etapa toca)

- `backend/nodebeat/switches.py`: descoberta (`descobrir`, sysDescr com as communities de `NODEBEAT_SNMP_COMMUNITIES`) e leitura (`ler_switch`: portas com `up` via IF-MIB ifOperStatus, FDB dot1d/dot1q, vizinhos LLDP).
- `worker.run_switches` a cada `switch_s` (600 s): para cada MK no ar, tenta os candidatos (`switches.candidato`) vistos no inventário; grava em `db.switches` (`mk_id`, `ip`, `gerenciavel`, `portas`, `fdb`, `erro`, `tentado_em`, `lido_em`…). Em produção hoje: 306 candidatos, todos "Sem resposta SNMP", nenhum lido.
- `mapa.py`: `ligacoes_e_raizes` sabe em qual (switch, porta) cada aparelho/switch está; a árvore MK → porta → switch → aparelhos já sai na tela Mapa de rede.
- `run_mapa` (60 s) pinga os aparelhos "vigiados"; switch gerenciável já é vigiado.
- MK: `portas_link` (todas as interfaces, running sim/não) no estado do Redis; "interfaces vigiadas" (lista manual por MK) já geram `interface_caida` que abre ticket.
- Syslog: associa o evento à MK pelo IP de origem (`syslog.mapa_ips`), grava em `eventos`.
- Webhook: `_emit` manda ao TiDesk só `queda` (e não `erro_acesso`); o `AlertEngine` já faz a janela contra oscilação.

## Design

### Contrato de tipo (backend)

Um módulo por tipo, registrado num dict simples `TIPOS = {"switch": switch_tipo}` (nada de plugin/loader). Cada tipo fornece:

- `rotulo` ("Switch") e os campos de cadastro além de nome/IP/local (switch: community, opcional, padrão = a primeira de `NODEBEAT_SNMP_COMMUNITIES`);
- `checar(equipamento) -> Observacao` (estado, detalhe, portas `{nome: {up, velocidade?}}`, uplinks);
- os estados possíveis (switch: `no_ar`, `offline`, `erro_acesso` = responde ping mas não SNMP).

Decisão do builder: a forma exata (Protocol, funções soltas num módulo). Mantém pequeno: um tipo só existe por enquanto.

### Dados

- Coleção nova `equipamentos`: `tipo`, `nome`, `ip`, `local` (`mk_id` do condomínio ou `"sede"`), `origem` (`"descoberto"` | `"manual"`), campos do tipo (community **cifrada** com `crypto`, como as senhas das MKs), `criado_em`.
- Switch descoberto: o worker cria/atualiza o `equipamento` quando `db.switches` marca `gerenciavel=True` (origem `descoberto`, nome = sysName/LLDP ou sysDescr curto ou o IP). Se deixar de ser gerenciável, o equipamento descoberto some da aba (o manual nunca some sozinho).
- `db.switches` continua sendo a leitura bruta usada pelo mapa; o `equipamento` é a identidade que a aba e os alertas usam. Decisão do builder se o manual também grava em `db.switches` (recomendado, para o mapa e a ligação funcionarem igual).
- Estado no Redis por equipamento (`state:eq:<id>`), no mesmo formato do `state:mk:*` (status, detalhe, desde, portas, atualizado_em).

### Leitura e intervalos (minha proposta)

- Ping de cada switch-equipamento a cada 60 s (junto do `run_mapa` ou num laço próprio do worker).
- Portas: walk só de ifName + ifOperStatus (+ ifHighSpeed para a velocidade) a cada 60 s nos switches gerenciáveis. É barato e permite o alerta de uplink em ~2 min. A leitura completa (FDB, LLDP) segue a cada 600 s.
- Offline após 2 ciclos sem ping, igual ao mapa. Ping ok e SNMP falhando = `erro_acesso` (sem ticket, como a MK).
- Switch da sede é lido direto da rede da sede (o CT tem uma interface em cada rede local da sede); o builder confere a rota até as outras redes da sede (o `rotas-tunel.sh` manda as redes privadas pelo gateway com o IP de origem configurado).

### Uplink

- Porta de **switch** é uplink se o mapa diz que por ela se chega a outro switch ou à MK (vizinho LLDP nessa porta, ou a porta pela qual o switch foi ligado ao pai em `ligacoes_e_raizes`, ou a porta onde aparece o MAC do pai). Sem marcação manual.
- **Switch burro** (decisão do dono): uma porta com **3 ou mais aparelhos vigiados** ligados nela, pelo mapa, também é uplink. É o caso do cabo solto que derruba várias câmeras de uma vez. O número 3 fica como constante no código.
- O "é uplink" de uma porta é lembrado depois que ela cai, porque com o link fora a FDB e o LLDP deixam de mostrar o que estava ligado. O builder decide como guardar isso.
- **MK**: mantém as "interfaces vigiadas" que já existem e já abrem ticket (não mexer em produção). Minha proposta: no desenho da MK, porta vigiada ganha uma marca (ex.: um ponto) e porta que leva a um switch aparece como uplink só visualmente; unificar a regra da MK fica para a migração da MK.

### Alertas e eventos

- Estados e janelas pelo `AlertEngine` (chaves novas `eq:<id>|eq` e `eq:<id>|uplink:<porta>`), mesma janela contra oscilação.
- Ticket (webhook) em: switch `offline` e `uplink_caido`. `erro_acesso` e porta comum: só tela e histórico.
- Porta comum que cai: vermelho na tela ("caiu", tinha link e perdeu) e evento no histórico, sem ticket. Volta para cinza quando o dono olhar? **Não**: proposta minha é ficar vermelha por 24 h ou até voltar o link, depois vira cinza (porta vazia não é problema).
- **Sem ticket em cascata** (call minha, pelo anti-objetivo): o alerta de um switch não abre ticket se o que está acima dele já está fora. Ou seja, a MK do condomínio não está `no_ar` (vale também para `vpn_caiu` e `erro_acesso`), ou o switch pai (pelo `ligacoes_e_raizes`) está `offline`. Nesses casos o estado aparece na tela e no histórico, mas o webhook não dispara. O laço do switch lê o `state:mk:*` e o `state:eq:*` do Redis para decidir.
- **Uplink sem ticket duplicado** (call minha): se a porta desce para um switch gerenciável monitorado, o ticket é o `offline` do filho, com a porta do pai no detalhe. A porta não gera um `uplink_caido` a mais. O `uplink_caido` sai quando a porta leva a algo que não tem alerta próprio (ver a pergunta do switch burro) ou quando o filho continua alcançável por outro caminho (uplink redundante).
- Payload do webhook (call minha, compatível): `mk` continua igual (condomínio; para a sede, `{"id": "sede", "nome": "Sede"}`, nunca `null`) e ganha `equipamento: {id, nome, tipo}`. O `detalhe` começa pelo nome do equipamento, para quem lê o ticket como texto. O dono confirma com a TI que o TiDesk não quebra com o campo novo.
- Syslog (call minha): `mapa_ips` passa a incluir os IPs dos equipamentos. O evento ganha `equipamento_id` e mantém `mk_id` quando for de MK. Se a MK fizer SNAT e o log do switch chegar com o IP dela, ele aparece na MK. É limitação conhecida, documentada na tela de ajuda do switch. Classificador de eventos do switch: fora desta etapa, os eventos aparecem crus no histórico do switch.
- Validação em produção: ligar o SNMP nos switches dos condomínios é ação do dono, fora do código. A validação real usa o USW-Pro-48 da sede (manual) e o primeiro switch de condomínio que o dono liberar. Testes cobrem o resto.

### API

- `GET /api/equipamentos?tipo=switch` (lista com estado), `POST /api/equipamentos` (só manual), `GET/PUT/DELETE /api/equipamentos/{id}` (descoberto: só renomear; não apaga), `GET /api/equipamentos/{id}/portas` (desenho), `GET /api/equipamentos/{id}/eventos`.
- `GET /api/mks/{id}/interfaces` ou o `/api/status` já trazem `portas_link` para o desenho da MK; reaproveitar.
- Mesma autenticação de hoje (`auth.current_user`).

### Telas (Flutter)

- **Abas no topo** (MK | Switch | Firewall), com contador de problemas em cada uma. MK = o dashboard atual sem mudança de conteúdo.
- **Aba Switch**: lista agrupada por local (Sede, depois cada condomínio), cada linha com bolinha de estado, nome, "N portas · M com link", há quanto tempo no estado. Botão "Adicionar switch" (nome, IP, local, community com o padrão já preenchido).
- **Tela do switch**: cabeçalho (nome, local, estado, descr, uptime se houver), o **desenho frontal estilo A**, detalhe da porta ao passar o mouse/clicar (nome, velocidade, há quanto tempo, o que está ligado: switch filho ou "N aparelhos" via mapa), histórico de eventos.
- **Tela da MK**: o mesmo componente de desenho no topo, alimentado por `portas_link`.
- **Componente do desenho**: um widget só (`painel_portas` ou nome do builder), montado pela lista de portas, sem desenho por modelo:
  - portas "de cobre" em duas fileiras (ímpar em cima, par embaixo), em grupos de 12 quando passar de 12;
  - SFP (nome com `sfp`, ou ifType/velocidade de fibra, decisão do builder) à direita;
  - interfaces que não são porta física ficam fora (bridge, vlan, pppoe, wireguard, ipsec, lo…): o builder define o filtro pelo nome (MK) e por ifType (SNMP);
  - cores pelos tokens do projeto: com link = `positiveFill`, sem link = cinza neutro do tema, caiu = `negativeFill`; uplink com marca própria. Os dois temas (claro e escuro) obrigatórios.

## Restrições

- Trade UI / tokens do projeto (cor de marca ciano só no NodeBeat); nada de cor solta.
- Community SNMP é segredo: nunca em log nem mensagem de erro; guardada cifrada.
- Nunca commitar IPs reais, domínio, communities.
- Produção (CT 119): worker, api, web mudam; o syslog muda só se o `mapa_ips` mudar (lembrar do `conntrack -D -p udp --dport 514` após recriar).
- TDD; backend e Flutter com testes; `flutter analyze` limpo.

## Deixado para o builder

- Formato exato do contrato de tipo e nomes de módulos.
- Filtro de interfaces físicas e detecção de SFP.
- Se o laço de 60 s das portas fica no `run_mapa` ou num laço próprio.
- Agrupamento de 12 em 12 e tamanho das portas em tela pequena.

## Calls minhas (o dono confere)

- Switch descoberto entra sozinho na aba; cadastro manual só para o que a MK não enxerga.
- Porta lida a cada 60 s; leitura completa segue em 600 s.
- Porta comum que caiu fica vermelha por até 24 h.
- MK mantém as interfaces vigiadas atuais para ticket; uplink automático só para switch nesta etapa.
- Aba Firewall aparece vazia até o projeto do firewall.
- Sem ticket em cascata (MK ou switch pai fora) e sem ticket duplicado de uplink quando o filho tem alerta próprio.
- Webhook: `mk` igual ao de hoje (sede = `{"id":"sede","nome":"Sede"}`) + campo novo `equipamento`.
- Log do switch que chegar pelo IP da MK (SNAT) fica na MK.

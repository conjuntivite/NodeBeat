# Alterações nas MKs pelo NodeBeat: trocar peer do IPsec e liberar porta para DVR

Data: 2026-11-26. Status: rascunho para aprovação.

## Intenção

Até hoje o NodeBeat só lê as MKs (e reinicia). Este projeto é a primeira **escrita**:

1. **Trocar o peer address do IPsec** de uma MK para um IP fixo escolhido pelo operador.
   *Por quê:* emergência. Quando o IP principal da sede cai, os túneis das MKs que apontam para ele caem junto, e o
   operador aponta a MK para outra saída da sede. MKs configuradas pelo domínio já sobem sozinhas pelo load balance, por
   isso é **uma MK por vez** (decisão do usuário), não uma troca em massa.
2. **Liberar uma porta para um IP interno** (port forward / `dst-nat` para um DVR, por exemplo).
   *Por quê:* comodidade e valor agregado: é mais fácil pelo NodeBeat que pela MK.

## Objetivos

- Botão por MK para trocar o peer, funcionando **com o túnel caído** (pelo IP público).
- Formulário por MK para criar um port forward, listar os criados pelo NodeBeat e removê-los.
- Toda alteração registrada (quem, quando, antes → depois, por qual caminho).
- Um script pronto na página Preparar MK, dizendo explicitamente que serve para o NodeBeat **alterar dados da MK
  (liberação de portas e IPsec)**.

## Não objetivos

- Troca em massa / "contingência da sede" (descartado pelo usuário).
- Liberar acesso de um IP externo à própria MK (filtro `input`) — o usuário não quer por agora.
- Mexer na MK da sede. Ela já precisa aceitar o túnel no IP novo; o NodeBeat não confere nem altera isso.
- Editar port forwards que não foram criados pelo NodeBeat.
- Ferramenta MCP para essas ações (fica para depois).

## Anti-objetivos (seria falha mesmo funcionando)

- O usuário `monitor` (senha usada pelo worker a cada minuto) ganhar `write`.
- O NodeBeat apagar ou alterar regra NAT que ele não criou.
- Port forward que sequestra serviço da própria MK (api-ssl, Winbox, portas alternativas) ou colide com outro forward.
- Senha de escrita aparecendo em log, resposta da API ou mensagem de erro.
- Commitar IPs, domínio ou nomes reais (regra do projeto): nos testes e docs, IPs de exemplo.

## Restrições do que existe hoje

- Acesso às MKs: `routeros._com_api` (API-SSL 8729, certificado fixado por SHA-256, `librouteros`).
- Caminho de rede: túnel (`ip_tunel`) e, só em **falha de rede** (`SemConexao`), `ip_publico` na 8729 e depois na
  `PORTA_API_ALT` (18729). Hoje isso está escrito dentro da rota `reiniciar` em `api.py`.
- Na MK, a api-ssl já aceita o NodeBeat + IPs públicos da sede (`/ip service ... address/available-from`) e o firewall
  tem `monitor-api` (túnel) e `monitor-api-wan` (lista `nodebeat-sede`). As regras são por porta, não por usuário:
  **valem para um usuário novo sem mudança**.
- O certificado da api-ssl é o mesmo para qualquer usuário: o pin `cert_sha256` da MK vale para a escrita.
- MKs v6 e v7 convivem (ex.: W96 v6.49, NDTV v7.24).
- Scripts da página Preparar MK são montados no navegador (`frontend/lib/mk_script.dart`), só ASCII, num bloco `{}`,
  linhas curtas (a cópia do terminal quebra linhas longas), e a senha **nunca vai ao servidor** pelo script.
- Front em Flutter web; visual do NodeBeat segue o padrão já usado nas telas (tokens do projeto, temas claro e escuro).

## Abordagens consideradas

1. **Segundo usuário só para alterações, `nodebeat-rw` (escolhida pelo usuário).** Grupo com `read,write,api`,
   aceito só do NodeBeat e dos IPs públicos da sede, senha própria guardada cifrada. `monitor` continua só leitura.
   Contra: o `write` do RouterOS não restringe a NAT/IPsec — quem tiver a senha, de um IP permitido, altera tudo.
2. Dar `write` ao `monitor`. Menos trabalho, mas a credencial mais usada passa a poder tudo. Descartada.
3. Scripts gravados na MK com `dont-require-permissions`, disparados pelo `monitor`. Não há jeito limpo de passar
   parâmetros (IP, porta) do API para o script; frágil. Descartada.

## Design

### 1. Credencial de escrita

**Na MK — cartão novo na Preparar MK.** Título: **"MK já cadastrada: permitir alterações pelo NodeBeat"**. Texto
explícito: "Cria o usuário `nodebeat-rw`, que o NodeBeat usa para alterar dados da MK: liberar portas (port forward)
e trocar o peer do IPsec. O usuário `monitor` continua só leitura."

O script (novo `scriptLiberarAlteracoes` em `mk_script.dart`, mesmo estilo do `scriptLiberarReinicio`):
- aborta com `:error` se o usuário `monitor` não existir (MK ainda não preparada);
- cria/atualiza o grupo `nodebeat-rw` com `policy=read,write,api`;
- cria/atualiza o usuário `nodebeat-rw` com a senha gerada no navegador (`gerarSenha()`) e `address=$lista`
  (NodeBeat + IPs públicos da sede, mesmo `_lista`);
- não toca em api-ssl, certificados nem firewall (já liberados pelo Preparar / Liberar Reinício);
- imprime no fim: `Usuario: nodebeat-rw` e a senha, para o operador colar no cadastro.
- Rodar de novo troca a senha (avisar no cartão, como o cartão do Preparar já faz).
- O `scriptDesfazer` passa a remover também o usuário e o grupo `nodebeat-rw`.

**No NodeBeat — cadastro da MK.** Campo novo opcional no formulário Editar MK: **"Senha de alterações
(nodebeat-rw)"**. Usuário fixo `nodebeat-rw` (constante, não editável). Gravado como `senha_rw_cifrada`
(`crypto.encrypt`, mesma chave). Vazio no PUT = mantém a atual (mesma regra da senha do `monitor`). Um botão
"Remover senha de alterações" no formulário apaga o campo (MK volta a só leitura no NodeBeat). `GET /api/mks/{id}`
devolve `tem_rw: bool`, nunca a senha.

Sem `tem_rw`, o detalhe da MK mostra os cartões de alteração desabilitados com o texto "Para alterar esta MK pelo
NodeBeat, aplique o script 'permitir alterações' da página Preparar MK e preencha a senha no cadastro."

### 2. Caminho até a MK (comum às duas funções)

Extrair a cascata da rota `reiniciar` para uma função reutilizável no `api.py` (ou `routeros.py`), algo como
`_na_mk(mk, fn, usuario, senha, ordem)`, que tenta os caminhos em ordem e só pula para o próximo em `SemConexao`,
devolvendo `(resultado, via)`. O `reiniciar` passa a usá-la (comportamento atual preservado e coberto pelos testes
que já existem).

- **Leituras e port forward:** túnel → IP público 8729 → IP público 18729 (igual ao reinício).
- **Troca de peer:** **IP público primeiro** (8729 → 18729) e túnel por último. Motivo: a troca derruba o túnel; pelo
  túnel a resposta pode se perder no meio. Na emergência o túnel já está caído de qualquer jeito.
- Erro de login/TLS/permissão nunca pula para outro caminho (regra atual).
- Mensagens de erro: `RouterOsError.detalhe`, nunca `str(e)` cru (regra atual). Permissão negada no `write` vira
  "Usuário nodebeat-rw sem permissão de escrita".

### 3. Trocar o peer do IPsec

**Leitura:** `GET /api/mks/{id}/ipsec/peers` → lê `/ip/ipsec/peer/print` (com o `monitor`, que tem `read`),
pelo caminho de leitura. Devolve por peer: `id` (`.id`), `nome` (`name`, existe na v7; na v6 pode faltar),
`endereco` (`address`), `desativado`, `comentario`, e `por_dominio: bool` (endereço não é IP). Devolve também `via`.

**Tela (detalhe da MK, cartão "IPsec"):**
- Lista os peers. Um só = já selecionado. Peer `por_dominio` aparece com a observação "pelo domínio: sobe sozinho
  pelo load balance" e o botão de troca dele fica disponível, mas com aviso.
- "Trocar peer" abre um diálogo: atalhos com os IPs públicos da sede (`settings.ips_publicos_sede`, já expostos em
  `/api/preparar-mk`) + campo livre para outro IPv4. Mostra "Atual: X → Novo: Y" e pede confirmação.
- Depois de aplicar: mostra o resultado e o caminho ("pelo IP público"/"pelo túnel").

**Escrita:** `PUT /api/mks/{id}/ipsec/peers/{peer_id}` com `{"endereco": "a.b.c.d"}`.
- Validação: IPv4 global (`is_global`), diferente do atual.
- Com `nodebeat-rw`, pelo caminho de troca de peer:
  1. relê o peer pelo `.id` (garante que existe e pega o endereço antigo);
  2. `/ip/ipsec/peer/set .id=<id> address=<novo>`;
  3. **v6:** nas policies com `sa-dst-address` igual ao endereço antigo do peer, faz `set sa-dst-address=<novo>`
     (na v6 a policy carrega o endereço do peer; na v7 ela aponta para o peer pelo nome e não precisa). Decidir pelo
     próprio registro: policy **com o campo `peer`** = estilo v7, não mexe (a v7 ainda mostra `sa-dst-address`, só
     leitura, derivado do peer, então a presença dele não serve de sinal); policy **sem `peer`** e com
     `sa-dst-address` = antigo → `set`. Erro nesse `set` entra na resposta ("peer trocado, policy X não") em vez de
     ser engolido. Confirmar com um print real de `/ip ipsec policy` de uma v6 e de uma v7 no primeiro passo do
     plano (fixture dos testes);
  4. relê o peer para confirmar o endereço novo;
  5. **aviso, sem escrita:** lê `/ip/firewall/filter` e `/ip/firewall/address-list` e, se alguma regra não
     desativada ou entrada de lista cita o endereço antigo (ex.: `input` liberando udp 500/4500 ou ipsec-esp só
     da sede antiga), a resposta lista essas regras: "o túnel pode não subir até ajustar estas regras". O
     NodeBeat não altera filtro.
  Se a conexão cair depois do passo 2 (possível pelo túnel), responder "Enviado; não deu para confirmar" e não erro.
- Grava no histórico (ver 5). Não altera nada no Mongo da MK (o `ip_tunel` não muda).

### 4. Liberar porta para um IP interno

**Listar:** `GET /api/mks/{id}/portas-liberadas` → lê `/ip/firewall/nat/print` ao vivo e devolve só as regras com
comentário começando por `nodebeat:`: protocolo, porta externa, IP interno, porta interna, descrição, `id`,
desativada. Devolve `via`.

**Criar:** `POST /api/mks/{id}/portas-liberadas` com
`{protocolo: "tcp"|"udp"|"ambos", porta_externa, ip_interno, porta_interna, descricao}`.
- `porta_interna` padrão = `porta_externa`. `descricao` obrigatória, até 40 caracteres, sem aspas
  (vira `comment=nodebeat:<descricao>`).
- **Validações antes de escrever:**
  - `ip_interno` IPv4 privado dentro de alguma rede da própria MK (`redes` do inventário). Inventário vazio ou
    desatualizado → aceita, mas a resposta avisa.
  - Porta externa reservada → recusa: 8729, 18729, 8291, 18291 e as portas dos serviços da MK (inventário
    `servicos`).
  - **Conflito ao vivo:** na mesma sessão da escrita, lê `/ip/firewall/nat/print` e recusa se algum `dstnat` não
    desativado já pega a mesma porta/protocolo (inclui faixas `a-b` e listas `a,b`; reaproveitar a lógica de
    `inventario.conferir_porta` sobre as linhas ao vivo, se couber).
- **Regra criada** (uma por protocolo; "ambos" = duas):
  `chain=dstnat action=dst-nat protocol=<p> dst-port=<ext> to-addresses=<ip> to-ports=<int>
  in-interface=<wan> comment=nodebeat:<descricao>`, numa **WAN só**.
  **WAN** = a interface que tem o `ip_publico` cadastrado (`/ip/address`); se nenhuma tiver, a interface da rota
  padrão ativa de menor `distance` (`/ip/route/print`, `dst-address=0.0.0.0/0`, `active`): gateway que já é
  interface; senão `immediate-gw` (v7, "ip%iface") ou `gateway-status` (v6, "... via iface"). Função pura
  testável, mesma ideia do script Preparar MK. Nenhuma WAN reconhecida → recusa com "WAN não reconhecida" e nada
  é criado. Motivo de não abrir em todas as WANs: com load balance (PCC/mangle) a resposta sai pela WAN principal
  e o forward na secundária não funciona sem mangle, que fica fora deste projeto. A tela mostra em qual WAN ficou.
  Posição: no fim do `dstnat` (não mover). Se criar uma das regras falhar, remove as que já criou nesta chamada.
- **Uma liberação = um grupo de regras** (1, ou 2 com "ambos"), identificado pela descrição: o comentário é
  `nodebeat:<descricao>` e a descrição é **única por MK** (o POST recusa repetida, comparando com os comentários
  ao vivo, sem diferenciar maiúsculas).
- Só NAT. Se a MK tiver filtro `forward` que bloqueia, a porta não abre: a tela avisa depois de criar ("Se não
  abrir, confira o filtro forward da MK").

**Listar** agrupa por comentário: uma linha por liberação, com os protocolos e a WAN.

**Remover:** `DELETE /api/mks/{id}/portas-liberadas?descricao=<descricao>` → relê ao vivo e remove **todas** as
regras com comentário exatamente `nodebeat:<descricao>`; nenhuma encontrada → 404. Regra sem o prefixo nunca é
tocada.

**Tela (detalhe da MK, cartão "Portas liberadas"):** lista as regras do NodeBeat com botão "Remover" (confirmação),
e "Liberar porta" abre o formulário: protocolo, porta externa, IP interno (sugestões vindas de `GET /mks/{id}/ips`,
campo livre também), porta interna, descrição. O formulário pode usar `GET /mks/{id}/portas/conferir` para avisar
cedo, mas a palavra final é a checagem ao vivo no POST.

### 5. Registro das alterações

Cada alteração bem-sucedida (e cada falha depois de começar a escrever) vira um evento no histórico da MK, pelo
mesmo `history.record(r, Event(...))` do reinício, tipo novo `alteracao`, com `detalhe` legível:
- "Peer IPsec <nome/id>: <antigo> → <novo>, por <usuario> pelo IP público"
- "Porta tcp 8080 → 192.168.x.50:80 liberada (DVR bloco B), por <usuario> pelo túnel"
- "Porta tcp 8080 (DVR bloco B) removida, por <usuario>"

O histórico já aparece no detalhe da MK e guarda 90 dias. O evento `alteracao` não abre alerta nem webhook. O
syslog da MK também registra a mudança (`config` com usuário `nodebeat-rw`), sem mudança no filtro do syslog.

### 6. Permissão no NodeBeat

Qualquer usuário logado pode usar (igual ao Reiniciar), com o nome registrado no histórico. *Chamada minha:* restringir
a administradores é uma troca de `current_user` por `admin_user` nas 4 rotas de escrita, se o usuário preferir.

## Testes

- Backend (pytest, padrão atual com `routeros` falso):
  - cascata de caminhos: ordem de leitura e de troca de peer; `SemConexao` pula, login/TLS não pula;
  - troca de peer v6 (atualiza `sa-dst-address` das policies certas) e v7 (não mexe em policy); IP inválido/igual;
    conexão perdida depois do `set` → "não confirmado";
  - descoberta de WAN (gateway interface, v7 `immediate-gw`, v6 `gateway-status`, nenhuma);
  - port forward: porta reservada, conflito ao vivo (porta única, faixa, lista), IP fora das redes, "ambos" cria
    duas, falha no meio desfaz, remoção recusa regra sem `nodebeat:`;
  - `tem_rw` no GET, senha nunca na resposta, PUT vazio mantém, remover apaga;
  - sem `senha_rw_cifrada` → rotas de escrita respondem 409 com a mensagem do Preparar MK.
- Front (flutter test): script `scriptLiberarAlteracoes` (só ASCII, linhas curtas, contém grupo/usuário/policy) e
  `scriptDesfazer` com o `nodebeat-rw`; cartões desabilitados sem `tem_rw`.
- Teste real (usuário): numa MK de teste, trocar o peer para outra saída da sede e voltar; liberar e remover uma
  porta de um DVR.

## Decidido pelo usuário

- Abordagem 1 (usuário `nodebeat-rw`).
- Troca de peer uma MK por vez, para IP fixo escolhido.
- Port forward só para IP interno (DVR); nada de liberar IP externo para a MK.
- Script explícito na Preparar MK dizendo que é para alterar dados (portas e IPsec).

## Chamadas minhas (para conferir)

- Troca de peer vai primeiro pelo IP público; leitura e port forward, primeiro pelo túnel.
- Atalhos com os IPs da sede + campo livre; peer por domínio pode ser trocado, com aviso.
- v6: atualizar `sa-dst-address` das policies sem campo `peer` junto com o peer.
- Regras de filtro/address-list que citam o IP antigo da sede: só avisar, não alterar.
- Port forward numa WAN só (a do IP público cadastrado; senão a rota padrão principal), no fim do `dstnat`,
  comentário `nodebeat:<descrição>` com descrição única por MK; remover apaga o grupo todo; só NAT, sem filtro
  `forward` nem mangle.
- MK `sem_ipsec`: cartão IPsec escondido.
- Registro no histórico existente (tipo `alteracao`), sem coleção nova.
- Qualquer usuário logado pode alterar.

## Deixado para quem implementar

- Onde fica a função de cascata (`api.py` ou `routeros.py`) e os nomes exatos.
- Layout fino dos cartões e diálogos, seguindo as telas atuais.
- Se vale fazer flush das SAs (`/ip/ipsec/installed-sa/flush`) depois da troca, caso o teste real mostre que o
  túnel demora a renegociar.

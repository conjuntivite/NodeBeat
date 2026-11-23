# NodeBeat — mapa de rede dos condomínios (fase A) — design

Data: 2026-11-23 · Status: rascunho para aprovação · Depende de: `2026-11-16-inventario-rede-design.md` (em produção)

## Intenção

Quando um aparelho de um condomínio cai (exemplo do usuário: o facial externo), quem atende precisa **achar o problema rápido**: olhar um mapa e ver "o facial externo está offline, na porta da MK que vai para o switch da garagem" e ir direto ao lugar, sem adivinhar. Referência de funcionamento: o monitor de switches da Ubiquiti, com árvore de pais e filhos.

Não é documentação de obra. O valor está em **achar** e **saber o que caiu junto**.

Hoje o NodeBeat sabe quais IPs foram vistos (lease + ARP, de hora em hora), mas não sabe **em que porta** cada um está, nem **se está no ar agora**.

## Fato que limita o desenho

Switch giga "normal" (não gerenciável: a maioria dos Intelbras/Hikvision/Haiz do usuário) **não tem IP nem MAC próprio na rede**. Nenhuma MK ou protocolo o enxerga. O que a MK sabe é **em qual porta dela** cada MAC aparece. Todos os aparelhos atrás do mesmo switch burro caem na mesma porta. Por isso a árvore da fase A tem este formato:

```
MK Condomínio X
├─ ether2  "Garagem"   ● 3 de 4 no ar
│   ├─ Hikvision 192.168.10.45  facial externo   ○ OFFLINE (há 12 min)
│   ├─ Hikvision 192.168.10.46                   ● no ar
│   └─ Intelbras 192.168.10.50                   ● no ar
└─ ether3              ● link caído  ← causa provável
    └─ NVR ...         ○ sem resposta
```

Níveis: **MK → porta da MK → aparelhos**. O switch burro nunca aparece como nó. Mostrar "só o switch" quando não dá para ver o que há depois dele (pedido do usuário) só é possível para switch que **tem IP** (ver "Switch com IP").

## Objetivos

1. Tela **Mapa de rede** no detalhe do condomínio: árvore MK → porta → aparelhos, com status de cada aparelho (no ar, offline, desconhecido) e de cada porta (link, quantos no ar).
2. Cada aparelho mostra **IP, MAC, fabricante, nome** (host do DHCP ou identidade LLDP/MNDP, se houver) e **última porta conhecida**.
3. **Aparelho offline continua no mapa**, sob a última porta onde foi visto, com "visto no ar há X". É o caso principal.
4. **Causa única:** porta com link caído, ou com todos os aparelhos vigiados sem resposta, aparece como **um** problema no nível da porta ("ether3: 6 de 6 sem resposta"), não como vários aparelhos soltos.
5. **Busca** por IP, MAC, nome ou fabricante, e filtro **só com problema**. O resultado mostra o caminho até o aparelho.
6. Zero cadastro obrigatório. Tudo vem da MK.

## Fora do escopo

- (A fase B, SNMP nos switches gerenciáveis, saiu do "fora do escopo" a pedido do usuário em 2026-11-23: está na seção **Fase B** abaixo, no plano como etapas separadas que só começam depois da fase A em produção.)
- Alertas, webhook ou ticket por aparelho. **Só tela.** (A lição do flapping do webhook, 70 tickets por oscilação, vale aqui: cem aparelhos oscilando abririam cem tickets.)
- Escrever qualquer coisa nas MKs. O NodeBeat continua só leitura (`read,api`).
- Classificar o tipo do aparelho (facial, câmera, NVR). O fabricante não distingue, pois a Hikvision faz os três. O usuário identifica pelo IP ou pelo apelido opcional.
- Desenho gráfico de grafo (linhas e caixas). Fase A é árvore recolhível; avaliar depois.
- Gráficos de histórico de disponibilidade dos aparelhos.

## Anti-objetivos (seria falha mesmo funcionando)

- **Mostrar aparelho "offline" quando o problema é a MK ou o túnel.** Se a MK não está `no_ar` na última leitura do ciclo, os aparelhos dela ficam **desconhecido** (cinza, "MK fora do ar desde X"), nunca vermelho.
- Dizer que um aparelho está "atrás do switch X" quando só sabemos a porta da MK.
- Dar à `monitor` qualquer permissão de escrita ou nova política além de `read,api`.
- Atrasar o ciclo de 30 s do monitoramento das MKs, ou a leitura horária do inventário. A checagem de aparelhos roda em tarefa própria.
- Sumir com um aparelho só porque desligou (o ARP e a tabela de MAC esquecem em minutos).
- Telefones e notebooks (MAC aleatório, entram e saem) aparecerem como "offline" e poluírem o mapa.

## Abordagens consideradas

- **A — Só pela MK (escolhida pelo usuário para agora).** Reaproveita a conexão e o inventário horário; acrescenta tabela de MAC por porta e vizinhos LLDP/MNDP. Sem credencial nova. Limite: switch burro invisível; árvore de 2 níveis.
- **B — A + SNMP/LLDP nos switches com IP (combinada para depois).** Árvore com níveis de verdade onde o switch responder. Pede community SNMP somente leitura por condomínio.
- **C — Cadastro manual da topologia.** Descartada pelo usuário.

## O que é lido de cada MK

Junto da leitura horária que já existe (`_MENUS_INVENTARIO` em `routeros.py`, mesma sessão, mesmo usuário `monitor`), acrescentar:

| Dado | Menu RouterOS | Campos usados |
|---|---|---|
| MAC → porta física | `/interface/bridge/host` | `mac-address`, `on-interface`, `bridge`, `vid`, `local` (ignorar `local=true`, que são MACs da própria MK) |
| Portas da bridge | `/interface/bridge/port` | `interface`, `bridge` |
| Vizinhos | `/ip/neighbor` | `mac-address`, `address`, `interface`, `identity`, `platform`, `board`, `system-caps` (se existir) |

Já lidos e reaproveitados: `/ip/arp` (`address`, `mac-address`, `interface`) e `/ip/dhcp-server/lease` (`host-name`, `dynamic`). O estado de link das portas vem de `ifaces` (`/interface/print`, já lido a cada 30 s e guardado no Redis).

Regra de **porta de um aparelho**, em ordem: (1) `on-interface` do bridge host com o mesmo MAC; (2) se o ARP aponta para uma interface que **não é bridge** (porta avulsa com IP), essa interface; (3) se o ARP aponta para uma bridge sem entrada no bridge host, **"bridge1 (porta desconhecida)"**; (4) nada novo: manter a **última porta conhecida** gravada. Interface VLAN aparece com o nome da VLAN.

Escolhas do designer:
- Esses menus extras são **opcionais**: se um falhar (MK sem bridge, versão sem o campo, policy sem permissão), registra-se o erro daquele item e o resto do inventário **continua gravando**. Não pode quebrar o inventário que já funciona.
- Funciona em RouterOS v6 (≥ 6.43) e v7. `system-caps` só existe em versões novas; sem ele, não se detecta switch por LLDP.

## Fabricante

Pelos 3 primeiros bytes do MAC, com uma **tabela pequena embutida no código** (Hikvision, Dahua, Intelbras, Control iD, Ubiquiti, MikroTik, TP-Link, Haiz, e o que o usuário apontar depois). MAC fora da tabela = "Outro". Sem dependência nova nem arquivo grande de OUI. Se o MAC tiver o bit de endereço administrado localmente ligado (`02`, `06`, `0A`, `0E` no 1º byte, típico de celular com MAC privado), o fabricante é "MAC privado".

## Quem é "vigiado" (tem ping e pode ficar vermelho)

Todo aparelho visto aparece no mapa. **Só alguns são pingados e ganham "offline"**:

- fabricante é de equipamento (tabela acima, exceto "Outro" e "MAC privado"), **ou**
- tem lease fixa no DHCP (`dynamic=false`).

Os demais aparecem cinza como "visto há X", sem alarme. Um clique por aparelho inverte a regra (**vigiar / parar de vigiar**), gravado no aparelho. Esse é o único estado escolhido por pessoa que o desenho exige, e é opcional.

## Checagem de queda

- Tarefa própria no worker, separada do ciclo de 30 s e do inventário, rodando **a cada 60 s** (variável de ambiente, como `interval_s`), com semáforo próprio (máx. 40 pings ao mesmo tempo) e o `probes.ping` que já existe (2 pacotes, 1 s).
- Pinga o IP de cada aparelho vigiado, visto nos últimos 15 dias (`DIAS_EM_USO`), cuja rede é **de túnel** (`tunel=true` no inventário da MK); o worker alcança essas LANs pelo mesmo caminho em que já pinga o IP do túnel de cada MK (rotas + SNAT do CT 119). Aparelho em rede fora do túnel fica "não vigiado (rede fora do túnel)".
- **Offline** só depois de **2 ciclos seguidos** sem resposta (evita piscada). Volta para "no ar" na primeira resposta. Guarda desde quando.
- Se a MK dona do aparelho não estiver `no_ar` no estado do Redis, o aparelho não é pingado e fica **desconhecido** (anti-objetivo acima).
- Estado volátil (no ar/offline, contagem de falhas, desde quando) fica no **Redis**, como o estado das MKs. Nunca gera evento, histórico nem webhook.

## Dados

Reaproveita o documento por (`mk_id`, `ip`) de `inventario_ips`, acrescentando: `porta`, `bridge`, `fabricante`, `identidade` (LLDP/MNDP), `plataforma`, `e_switch` (LLDP diz `bridge`), `vigiar` (regra automática, com `vigiar_manual` opcional que a sobrepõe) e `apelido` (opcional). A última porta conhecida só é sobrescrita quando uma leitura nova trouxer porta; **nunca** se apaga por ausência. "Esquecer IP" (já existe) continua apagando o aparelho do mapa.

Rótulo opcional por porta (ex.: "Garagem"): pequeno mapa `porta → texto` no documento `inventario` da MK. Vazio por padrão, sem prejuízo ao mapa.

## Switch com IP (o que a fase A já faz por ele)

Quem tiver `system-caps` com `bridge` no LLDP/MNDP, ou o usuário marcar como switch, é desenhado **primeiro dentro da porta**, com o ícone de switch e a nota "aparelhos desta porta podem estar atrás dele". Sem inferir pai. É o gancho natural para a fase B.

## Fase B — switch gerenciável aparece sozinho, com tudo atrás dele

Pedido do usuário: ao instalar um switch gerenciável num condomínio, o NodeBeat **reconhece que ele é gerenciável e traz tudo que está atrás dele**, sem cadastro.

- **Descoberta automática:** todo IP de aparelho visto (nas redes de túnel) que for candidato a switch recebe, na leitura horária, uma tentativa de **SNMP v2c** (`sysDescr`, porta UDP 161) com as communities configuradas. Quem responder vira `gerenciavel=true` e passa a ser lido. Candidato = LLDP/MNDP diz `bridge`, ou fabricante de rede da tabela (Intelbras, Haiz, Hikvision, TP-Link, MikroTik, Ubiquiti), ou marcado à mão como switch. Quem não responde ao SNMP mas o LLDP diz que é switch aparece com a dica **"gerenciável detectado: ative o SNMP nele"**.
- **Credencial:** lista de communities somente leitura em variável de ambiente (padrão `public`), tentadas em ordem; a que funcionou fica guardada **cifrada** (mesmo `crypto` das senhas) no switch. Override por MK opcional. Nenhuma escrita: só `get`/`walk`.
- **O que se lê do switch:** tabela de MAC por porta (`BRIDGE-MIB` dot1dTpFdb + `dot1dBasePortIfIndex`, ou `Q-BRIDGE-MIB` dot1qTpFdb quando houver VLAN), nome e estado das portas (`IF-MIB` ifName, ifOperStatus) e vizinhos (`LLDP-MIB` lldpRemTable).
- **Montagem da árvore (função pura):** o ponto de ligação de um aparelho é a porta do switch **que menos MACs aprendeu** entre as que o conhecem (a mais perto da ponta). Um switch cuja uplink aponta para a MK, ou para outro switch, fica filho dele. Resultado: `MK → porta → switch → porta do switch → aparelhos` e switches em cascata. Aparelho que nenhum switch gerenciável conhece continua só sob a porta da MK, como na fase A.
- **Status:** porta do switch com link caído ou com todos os filhos sem resposta vira causa única no nível dela, como na fase A. Switch gerenciável que parar de responder ao ping vira offline e seus filhos viram **desconhecido** (não vermelho), pois a causa é o pai.
- **Limites honestos:** depende do modelo ter SNMP (a maioria dos gerenciáveis tem, mas costuma vir desligado: o usuário ativa uma vez). Switch burro no meio continua invisível; os aparelhos dele ficam agrupados na porta do switch gerenciável acima.
- **Leitura mais frequente do switch:** a tabela de MAC de switch gerenciável lê **a cada 10 min** (configurável), não de hora em hora, porque é nela que está o "onde está".
- **Decisão (B1, 2026-11-23): cliente SNMP próprio, só stdlib** (`nodebeat/snmp.py`: BER mínimo + asyncio UDP, GET e GETBULK, sem SET). O `pysnmp` 7.1.33 instalou limpo no Python 3.14 e respondeu no spike, mas traz `pysnmp` + `pyasn1` e um motor SNMP inteiro (v3, MIBs) para usar só dois comandos, com API que já mudou muito entre versões. O cliente próprio tem ~200 linhas, zero dependência nova, e o teste compara o GET gerado com o BER de referência do `pysnmp`. Sem retransmissão: pacote perdido falha a leitura e o próximo ciclo tenta de novo.

## API

Todos os endpoints exigem login. Nomes ficam a cargo de quem construir. Funções:
- mapa de uma MK: árvore (portas com status e rótulo, aparelhos com estado e dados), com `lido_em` do inventário e aviso de "desatualizado" no mesmo padrão de hoje (> 2 h);
- editar um aparelho (apelido, vigiar sim/não, é switch) e rótulo de porta;
- o botão **atualizar** do inventário que já existe passa a atualizar também o mapa.

A montagem da árvore (agrupar por porta, status de porta, causa única, filtro de busca) fica numa **função pura** em módulo do backend, testada sem Mongo, Redis nem MK, para a fase B poder estendê-la.

## Painel (Flutter)

Segue o Trade UI, temas claro e escuro. Nova seção/tela **Mapa de rede** no detalhe do condomínio (`mk_detail`), reaproveitando `widgets/inventario.dart` onde couber.
- Árvore recolhível, com portas que têm problema **abertas por padrão** e as sadias recolhidas.
- Cor com **ícone e texto junto** (nunca só cor): `positive` no ar, `negative` offline, cinza desconhecido, `warning` desatualizado/porta desconhecida.
- Campo de busca e chave "só com problema". Layout que funcione em celular, pois é o uso de campo.
- Uma cor de marca por tela e demais regras do Trade UI.

## Sobra para quem for construir

- Nomes de endpoints, coleções e campos; formato exato do JSON da árvore.
- Onde fica cada função pura (módulo novo `mapa.py` é o natural).
- Como tratar VLANs e bridges múltiplas além do descrito.
- Tabela inicial de fabricantes (começar com a lista acima).
- Carga: ~20 MKs × dezenas de aparelhos vigiados a cada 60 s deve caber no semáforo; medir no deploy.

## Calls do designer (conferir)

1. Árvore recolhível em lista, não grafo desenhado.
2. Só vigia (ping/vermelho) fabricante de equipamento ou lease fixa; resto fica cinza.
3. Offline após 2 ciclos de 60 s (~2 min).
4. Ping direto do worker pelos túneis, não via MK.
5. Estado de ping no Redis, dados duráveis no Mongo.
6. Apelido de aparelho e rótulo de porta opcionais, nunca exigidos.
7. Sem alerta, webhook ou ticket por aparelho.

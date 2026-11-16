# NodeBeat — inventário de rede das MKs — design

Data: 2026-11-16 · Status: aprovado · Depende de: `2026-11-11-monitor-mk-design.md` (fase 1, em produção)

## Intenção

Hoje são ~20 MKs, uma por condomínio, todas com IPsec até o SonicWall da sede, e **cada uma foi configurada de um jeito, sem padrão de faixa** (fato do usuário). Dois problemas recorrentes:

1. **Condomínio novo (a MK 21):** antes de configurar, é preciso escolher a faixa de rede interna com certeza de que nenhuma das outras MKs (nem a sede) usa essa faixa. Faixa repetida quebra o roteamento pelo IPsec.
2. **Equipamento novo num condomínio existente** (o caso do dia a dia: DVR novo no controle de acesso): é preciso escolher uma **porta pública livre no NAT daquela MK** e um **IP interno livre** na faixa do condomínio.

Também se quer enxergar, **por segurança**, o que cada MK deixa aberto para a internet.

O NodeBeat já conecta em todas as MKs com um usuário só de leitura. Ele passa a guardar esse inventário e a oferecer conferências ("esta faixa/porta/IP está livre?").

## Objetivos

1. Tela **Faixas de IP**: todas as redes de todas as MKs e da sede, marcando as que vão pelo túnel, avisando sobreposições existentes e com um campo **conferir faixa** (CIDR).
2. No detalhe do condomínio, **Portas**: redirecionamentos (dst-nat) e serviços da própria MK, com destaque do que está aberto para qualquer IP, e um campo **conferir porta**.
3. No detalhe do condomínio, **IPs**: IPs internos já vistos (DHCP + ARP), com data da última vez visto, e um campo **conferir IP**.
4. Leitura automática **a cada hora** (decisão do usuário) e botão **atualizar** para ler na hora.

## Fora do escopo

- Escrever qualquer coisa nas MKs. O NodeBeat continua **só leitura**. O "script configurador de MKs" é uma ferramenta futura e separada, que pode consultar este inventário. Ela não é parte deste trabalho.
- Sugerir automaticamente "a próxima faixa livre": não há padrão a seguir. O sistema só mostra o que está em uso e confere a faixa escolhida por uma pessoa.
- Padronizar portas entre condomínios (o conflito que importa é dentro da mesma MK; decisão do usuário).
- Avisar por webhook sobre sobreposição, porta aberta etc. Fica só na tela.
- Histórico de mudanças de NAT, firewall ou faixas. Guarda-se apenas a última leitura (exceto os IPs vistos, abaixo).

## Anti-objetivos (seria falha mesmo funcionando)

- Dar ao usuário `monitor` qualquer permissão nova de escrita. A política `read,api` atual tem que bastar.
- Uma conferência dizer **"livre"** quando faltam dados de alguma MK (VPN caída, nunca lida, leitura antiga). Nesse caso a resposta tem que dizer **"livre nas MKs lidas, mas faltam: X, Y"**.
- Esquecer um IP só porque o equipamento estava desligado na hora da leitura.
- Atrapalhar o monitoramento: uma leitura de inventário lenta ou com erro não pode atrasar o ciclo de 30 s nem gerar evento ou alerta.

## Abordagens consideradas

- **A — Dentro do NodeBeat (escolhida pelo usuário).** O worker ganha uma leitura horária que reaproveita a conexão existente (usuário `monitor`, API-SSL com certificado fixado, cadastro de MKs). Os dados ficam no Mongo, a API ganha endpoints e o Flutter ganha telas. É a mais trabalhosa, mas fica tudo onde a equipe já trabalha, sem credencial nem deploy novos, e com histórico de IPs vistos.
- **B — Script de linha de comando separado.** Mais barato, mas só quem tem acesso ao servidor usa, e o histórico de IPs precisaria de agendamento próprio.
- **C — Ler na hora, sem guardar.** Descartada: não lembra de equipamento desligado, e uma MK com VPN caída some da conferência, que é justamente quando dá para repetir faixa sem perceber.

## O que é lido de cada MK

Tudo com o usuário `monitor` existente (política `read,api`), pela mesma conexão `_com_api` de `backend/nodebeat/routeros.py`, numa única sessão por MK. Precisa funcionar em RouterOS v6 (≥ 6.43) e v7.

| Dado | Menu RouterOS | Campos usados |
|---|---|---|
| Redes das interfaces | `/ip/address` | `address` (CIDR), `interface`, `disabled` |
| Redes do DHCP | `/ip/dhcp-server/network` | `address` |
| Pools | `/ip/pool` | `name`, `ranges` |
| Túnel IPsec | `/ip/ipsec/policy` | `src-address` (rede do condomínio), `dst-address` (rede da sede), `disabled`; ignorar `template=true` e o `default` |
| Redirecionamentos | `/ip/firewall/nat` com `action=dst-nat` | `protocol`, `dst-port`, `dst-address`, `in-interface`, `src-address`, `src-address-list`, `to-addresses`, `to-ports`, `comment`, `disabled` |
| Serviços da MK | `/ip/service` | `name`, `port`, `address`, `disabled` |
| IPs conectados | `/ip/dhcp-server/lease` e `/ip/arp` | `address`, `mac-address`, `host-name` (lease), `interface` (arp) |

Escolhas do designer:
- Endereços de `/ip/address` **dinâmicos** (do PPPoE/DHCP-client do WAN) e o IP do próprio túnel não são "faixa do condomínio". Entram como redes da MK apenas os estáticos de interfaces que não são a WAN. Como o cadastro não tem o campo WAN, a regra é: **ignorar endereços `dynamic=true` e os /32**. O resto conta.
- Faixas de `/ip/address` e do DHCP são normalizadas para a rede (`192.168.10.1/24` → `192.168.10.0/24`) com `ipaddress` da stdlib.

## Faixas de IP (tela global)

- Lista por condomínio: as redes da MK, cada uma marcada **túnel** se estiver contida em algum `src-address` de política IPsec ativa. Mostra também a hora da última leitura bem-sucedida.
- **Redes da sede:** cadastradas à mão na variável de ambiente `SEDE_REDES` (lista de CIDRs separada por vírgula), numa linha "Sede". Não são deduzidas das políticas IPsec, porque uma MK com `dst-address=0.0.0.0/0` ou um resumo largo faria "a sede" cobrir tudo (achado da revisão).
- **Só as redes de túnel bloqueiam** (decisão do usuário). Redes fora do túnel (ex.: WAN estático atrás do modem do provedor, rede de visitantes) aparecem na lista, mas só geram **aviso**.
- **Sobreposições:** um par de redes **de túnel** de MKs diferentes, ou rede de túnel × sede, que se sobreponha (`ipaddress.overlaps`) gera um alerta no topo. Redes repetidas **dentro** da mesma MK e sobreposições entre redes fora do túnel não geram alerta.
- **Conferir faixa:** recebe um CIDR. Responde `em uso` se colide com rede de túnel de alguma MK ou com a sede (lista quem colide). Senão responde `livre`, com aviso se colidir com rede fora do túnel ("o Condomínio C usa essa rede localmente, fora do túnel"). Se alguma MK nunca foi lida ou tem a última leitura com mais de 2 h, a resposta inclui "faltam dados de: …", mesmo quando é `livre`.

## Portas (por condomínio)

- Tabela dos dst-nat: porta pública (protocolo + `dst-port`) → `to-addresses:to-ports`, comentário e se está desativada.
- Serviços ativos da MK (`/ip/service` não `disabled`) com sua porta.
- **Aberto para qualquer IP:** dst-nat ativo sem `src-address` e sem `src-address-list`; serviço ativo com `address` vazio. Destacado. O texto deve deixar claro que é "sem restrição na regra/serviço" (o firewall pode ainda filtrar). Nesta fase **não** se analisa a chain `input` do firewall.
- **Conferir porta:** recebe porta e protocolo (tcp/udp; padrão tcp). Está **em uso** se bater com um dst-nat ativo do mesmo protocolo (ou sem protocolo) ou com a porta de um serviço ativo da MK (serviços são TCP). `dst-port` pode vir como lista ou faixa (`80,443`, `8000-8010`) e as duas formas têm que ser tratadas. Regras desativadas aparecem na resposta como aviso ("existe regra desativada com essa porta"), sem bloquear. Um dst-nat ativo **sem** `dst-port` ocupa todas as portas do protocolo.

## IPs (por condomínio)

- A cada leitura, todo IP visto em lease DHCP ou na ARP **dentro das redes da MK** é gravado/atualizado com `mac`, `host_name` (se houver), `fixo` (lease estática, `dynamic=false`), `primeiro_visto` e `ultimo_visto`. Um IP **não se apaga** por não aparecer. Só sai pelo botão **esquecer** (por IP, na tela).
- Tabela ordenada por IP, com a data da última vez visto.
- **Conferir IP:** responde
  - `fora da faixa` se o IP não pertence a nenhuma rede da MK;
  - `em uso` se tem lease fixa no DHCP ou foi visto nos **últimos 15 dias** (decisão do usuário), com mac, host e última vez;
  - senão `livre`, com aviso se foi visto há mais de 15 dias ("visto em DD/MM, mac/host") e aviso se o IP cair dentro de um pool do DHCP ("está no pool do DHCP; pode ser entregue a outro equipamento").
- Mesmo aviso de "faltam dados" da faixa: se a última leitura da MK tem mais de 2 h, a resposta diz isso. Vale também para conferir porta.

## Leitura e atualização

- No worker, uma tarefa separada do ciclo de 30 s roda o inventário **a cada 1 h** (configurável por variável de ambiente, como `interval_s`). Tem o **seu próprio** semáforo (máx. 10 MKs ao mesmo tempo), para não disputar com o ciclo de 30 s, e o mesmo timeout por MK. **Não** passa pelo motor de alertas e não gera eventos.
- MK que falhar fica com a leitura anterior e um campo de erro (`lido_em` antigo + `erro`), para a tela mostrar "leitura de 3 h atrás: VPN caiu".
- Enquanto a referência da sede estiver em `falha_sede`, o inventário não roda.
- **Botão atualizar:**
  - No detalhe do condomínio, a API lê aquela MK na hora (mesmo padrão do endpoint `/interfaces` atual, via `asyncio.to_thread`) e grava.
  - Na tela Faixas de IP, a API grava um pedido no Redis e o worker antecipa a próxima leitura completa. A tela mostra "atualizando…" até `lido_em` mudar.
- Primeira leitura logo que o worker sobe.

## Dados

Mongo (mesmo banco `nodebeat`):
- `inventario`: um documento por MK (`mk_id`, `lido_em`, `erro`, `redes`, `ipsec`, `pools`, `nat`, `servicos`), substituído a cada leitura bem-sucedida.
- `ips_vistos`: um documento por (`mk_id`, `ip`), com índice único nesse par.
- Apagar uma MK apaga também o inventário e os IPs vistos dela.

## API

Todos os endpoints exigem login (como os atuais). Nomes ficam a cargo de quem construir. Funções:
- listar faixas + sobreposições; conferir faixa;
- portas de uma MK; conferir porta;
- IPs de uma MK; conferir IP; esquecer IP;
- atualizar uma MK; pedir atualização de todas.

A lógica de conferência (sobreposição de CIDR, porta em lista/faixa, IP em rede/pool) fica em **funções puras** num módulo próprio do backend, testadas sem Mongo nem MK.

## Painel (Flutter)

Segue o Trade UI, como o resto do painel, nos temas claro e escuro.
- Nova entrada **Faixas de IP** a partir do dashboard.
- No detalhe do condomínio (`mk_detail`), duas seções novas: **Portas** e **IPs**, cada uma com seu campo de conferir e o botão atualizar.
- O resultado das conferências usa `positive` para livre, `negative` para em uso e `warning` para "faltam dados" e avisos.

Esboço:
```
Faixas de IP              lido 14:00  [atualizar]   [ conferir faixa ______ ] ✓ livre
⚠ Condomínio C e Condomínio D sobrepõem 10.30.0.0/24 (túnel)
Condomínio A   192.168.10.0/24 (túnel)  192.168.1.0/24        lido 14:00
Condomínio B   10.0.0.0/24 (túnel)                             ⚠ leitura de 11:00: VPN caiu
Sede           10.1.0.0/16
```

## Segurança

- Sem permissão nova nas MKs; sem porta nova aberta.
- Os dados de inventário (faixas, NAT, MACs) são internos: ficam atrás do login do painel, como o resto.
- Nunca logar exceção com argumentos (regra já existente: pode conter senha).
- IPs e dados reais **não** entram em commits, testes nem documentação (usar exemplos fictícios).

## Fica a cargo de quem construir

- Nomes dos endpoints, módulos e campos internos.
- Layout exato das telas dentro do Trade UI.
- Se a leitura do inventário reaproveita `_com_api` com uma função nova (`fetch_inventario`) ou outra organização equivalente.
- Paginação e ordenação das tabelas (são ~20 MKs e algumas centenas de IPs por MK).

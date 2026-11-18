# NodeBeat — SISLOG (eventos das MKs) — design

Data: 2026-11-18 · Status: rascunho · Depende de: `2026-11-11-monitor-mk-design.md`, `2026-11-17-preparar-mk-design.md` (em produção)

## Intenção

O usuário quer **controle real** das MKs a partir do NodeBeat. Hoje o NodeBeat sabe se a MK está no ar, o inventário e o histórico de alertas, mas não o que acontece **dentro** dela (quem entrou, o que mudou, qual interface caiu, se o IPsec renegociou). O SISLOG faz as MKs mandarem seus eventos ao NodeBeat, que os guarda **já classificados** e mostra no painel.

É o primeiro de três projetos, nesta ordem (decisão do usuário):
1. **SISLOG** (este).
2. **Servidor MCP só leitura**: o Claude consulta o NodeBeat (MKs, status, inventário, eventos do SISLOG) e devolve dados estruturados. Autentica com o usuário administrador. Por isso os eventos precisam ser guardados com campos estruturados, não só a linha crua.
3. **Liberar portas para um IP numa MK** pelo painel. É a primeira escrita nas MKs e terá um design próprio.

## Objetivos

1. Receber o log remoto (syslog UDP) de cada MK pelo túnel IPsec, identificar a MK de origem e guardar cada evento classificado (`tipo` + campos extraídos).
2. Um cartão **Eventos** no detalhe da MK, com filtro por tipo e por período.
3. Um endpoint de API com filtros, que o painel usa e que o projeto MCP vai reaproveitar.
4. O Preparar MK passa a ensinar a MK a mandar os eventos. Há também um script curto, só do syslog, para as ~20 MKs que já estão em produção.

## Fora do escopo

- Alertas ou webhook disparados por eventos (ex.: "5 falhas de login em 1 min"). Fica para depois. O formato guardado já permite.
- Logs de firewall (`topics=firewall`), por causa do volume. Podem entrar depois, com retenção própria.
- Syslog por TCP/TLS (só existe na v7 e o caminho já é cifrado pelo IPsec).
- Visão de eventos de todas as MKs numa tela só. O MCP cobre a consulta cruzada no projeto 2.
- MCP e liberar portas (projetos 2 e 3).

## Anti-objetivos (seria falha mesmo funcionando)

- O receptor cair, encher ou ficar lento e isso afetar o worker (ciclo de 30 s), a API ou o painel.
- Guardar linhas de IP que não é uma MK cadastrada.
- O Mongo crescer sem limite: os eventos antigos precisam sumir sozinhos.
- Para ligar o syslog numa MK existente, ser preciso rodar de novo o script completo do Preparar MK. Esse script **troca a senha do usuário `monitor`** e quebraria o cadastro.
- Dar ao usuário `monitor` qualquer permissão nova. O envio de log é configurado por uma pessoa com admin, colando o script.

## Abordagens consideradas

- **A — Receptor próprio dentro do NodeBeat (escolhida pelo usuário).** Um serviço `syslog` novo no compose, com a mesma imagem do backend. Usa o `asyncio` da stdlib e não traz dependência nova. Classifica em Python e grava no Mongo com TTL. Painel e MCP leem do mesmo lugar.
- **B — rsyslog/syslog-ng na frente, NodeBeat importa.** Aguenta volume enorme, mas acrescenta uma peça e duas configurações, e a classificação continuaria em Python. Só compensaria com o firewall ligado por inteiro.
- **C — Graylog ou Loki/Grafana.** Pesado para o CT de 4 GB (o Graylog exige OpenSearch). Os eventos ficariam numa segunda interface, fora do painel e do MCP, contra a intenção.

## Caminho do pacote

```
MK (src-address = ip_tunel, a LAN da MK)
  → IPsec → SonicWall da sede → <IP_NODEBEAT_TUNEL>:514/udp (eth1 do CT 119)
  → Docker publica ${NODEBEAT_SYSLOG_BIND_IP}:514 → container syslog :5514/udp
```

- O `src-address` da action remota **tem que ser o IP da LAN da MK** (o `ip_tunel` do cadastro). É isso que faz o pacote casar com a policy IPsec e o que identifica a MK no receptor.
- No container, o processo roda como o usuário `nodebeat` (sem root), por isso ouve em **5514**. O compose mapeia a 514 do host para ela.
- **Confirmado no spike** (`docs/spike-syslog.md`):
  - o pacote chega sem regra nova no SonicWall;
  - o `rp_filter` do CT já é frouxo;
  - o Docker preserva o IP de origem pelo DNAT.
- **Armadilha do conntrack:** um fluxo UDP antigo continua indo para o destino anterior, e a MK nunca para de mandar. Por isso:
  - o container `syslog` tem **IP fixo** na rede do compose;
  - o deploy roda `conntrack -D -p udp --dport 514` depois de subir ou recriar o serviço (o pacote `conntrack` já está no CT).

## Receptor (`backend/nodebeat/syslog.py`, `python -m nodebeat.syslog`)

- `asyncio` `DatagramProtocol` em `0.0.0.0:5514`. Datagrama maior que 2048 bytes é cortado, e o texto é decodificado com `errors="replace"`.
- **IP repetido:** duas MKs com o mesmo `ip_tunel` não funcionam juntas atrás do mesmo IPsec, porque a sede não roteia a mesma LAN para dois túneis. Mesmo assim, o cadastro hoje aceita (chamada do designer, dois pontos):
  - `POST`/`PUT /api/mks` passam a recusar `ip_tunel` já usado por outra MK, com 422 no campo `ip_tunel`.
  - O receptor descarta eventos de IP que aponta para mais de uma MK e conta esses descartes à parte no log.
  - No deploy, conferir antes se já existe duplicado em produção.
- **IP → MK:** um dicionário `ip_tunel → mk_id`, carregado do Mongo ao subir e recarregado a cada 60 s. Também recarrega na hora quando chega um IP desconhecido, no máximo uma vez a cada 10 s. Isso cobre MK recém-cadastrada sem martelar o Mongo. IP que continua desconhecido é descartado e contado. A contagem vai para o log do container, uma linha por minuto no máximo, com os IPs.
- **Gravação em lote:** os eventos vão para uma fila em memória e entram com `insert_many` a cada 1 s ou a cada 500 eventos. A fila tem teto de 10 000. Acima disso o evento é descartado e contado, para o processo não estourar a memória se o Mongo travar.
- **Limite por MK:** no máximo 50 eventos/s por MK, numa janela simples de 1 s. O excedente é descartado e contado no mesmo log. `ponytail:` janela fixa; troque por token bucket se aparecer rajada legítima perdida.
- **Descartes de ruído (spike):** antes da fila, sem contar como evento:
  - linha com o tópico `debug`;
  - `login`/`logout` do usuário `monitor` vindo de `NODEBEAT_IP_ORIGEM`, que é o próprio NodeBeat a cada 30 s. Gera ≈ 2 880 linhas por dia por MK.
- **Saúde:** grava `syslog:vivo` no Redis com TTL de 90 s a cada 30 s, no mesmo padrão do `worker:vivo`. O `/api/status` **não** passa a depender disso nesta fase. Fica só para consulta e para o MCP depois.
- O receptor não fala com o worker nem com a API. Se ele cair, o resto segue igual (`restart: unless-stopped`).

## Parser e classificação (`backend/nodebeat/eventos.py`, funções puras)

Entrada: bytes do datagrama. Saída: dicionário do evento.

1. **Formato (spike):** v6 com `bsd-syslog=no` e v7 com `remote-log-format=default` mandam só `topicos mensagem`, sem PRI, sem hora e sem nome da MK. Ex.: `system,error,critical login failure for user admin from 203.0.113.10 via winbox`. **A data é `recebido_em`**, a hora do NodeBeat.
2. **Tópicos:** o 1º token, separado por vírgula → `topicos: ["system","error","critical"]`. O resto é `mensagem`. Uma linha cujo 1º token não parece lista de tópicos (`[a-z0-9-]+(,[a-z0-9-]+)*`) fica com `topicos: []` e `mensagem` inteira. Isso é tolerância a MK mal configurada.
3. **Severidade pelos tópicos:** `critical` → `crit`, `error` → `err`, `warning` → `warning`, `debug` → `debug`, senão `info`.
4. `tipo` + `campos` por uma tabela de regex, avaliadas em ordem e parando na primeira que casar:

| tipo | exemplo de mensagem (RouterOS) | campos |
|---|---|---|
| `login` | `user admin logged in from 10.0.0.5 via winbox` | `usuario`, `ip`, `via` |
| `login_falha` | `login failure for user admin from 10.0.0.5 via ssh` | `usuario`, `ip`, `via` |
| `logout` | `user admin logged out from 10.0.0.5 via winbox` | `usuario`, `ip`, `via` |
| `config` | v6 `log rule added by admin`. v7 `log rule added by tcp-msg(winbox):admin@203.0.113.10/terminal (*9 = ...)` | `usuario`, `objeto` (`log rule`), `acao` (`added`/`changed`/`removed`), e na v7 `via` e `ip` |
| `interface` | `ether1 link down`, `ether1 link up (speed 1G, full duplex)` | `interface`, `estado` (`up`/`down`) |
| `ipsec` | tópico `ipsec` (ex.: `phase1 negotiation failed`) | `peer` quando houver IP |
| `dhcp` | `dhcp1 assigned 192.168.88.10 to AA:BB:CC:DD:EE:FF` | `servidor`, `ip`, `mac` |
| `pppoe` | tópico `pppoe` / `ppp` (ex.: `pppoe-out1: connected`) | `interface`, `estado` |
| `reboot` | `router rebooted`, `system,info,critical ... rebooted` | — |
| `erro` | severidade ≤ `err` ou tópico `critical`/`error` sem regra acima | — |
| `outro` | o resto | — |

As amostras reais do spike (anonimizadas) estão em `backend/tests/amostras_syslog.txt` e viram casos de teste. Os exemplos de `interface`, `dhcp`, `pppoe`, `ipsec` e `reboot` não apareceram no spike e seguem o formato do manual. Ajustar quando aparecerem em produção.

## Armazenamento (coleção `eventos`)

```
{ mk_id: str, recebido_em: datetime(UTC), severidade: str,
  topicos: [str], tipo: str, campos: {..}, mensagem: str }
```

- Índice `(mk_id, recebido_em desc)` para a listagem e índice TTL em `recebido_em` com `expireAfterSeconds = NODEBEAT_SYSLOG_DIAS × 86400` (padrão **30 dias**, chamada do designer). O receptor cria os índices ao subir. Se o número de dias mudar, ajusta o TTL com `collMod`.
- Ao apagar uma MK, `delete_mk` também apaga os eventos dela, no mesmo padrão do `apagar_inventario`.
- Funções em `store.py`: `inserir_eventos`, `listar_eventos(mk_id, tipos, desde, ate, q, limite)`, `apagar_eventos(mk_id)`.

## API

`GET /api/mks/{id}/eventos?tipo=login&tipo=config&desde=<ISO>&ate=<ISO>&q=<texto>&limite=200`

- Exige sessão, como as outras rotas de `/mks`. MK inexistente → 404.
- `tipo` repetível. `q` é busca simples, sem diferenciar maiúscula, em `mensagem` (regex escapada com `re.escape`). `limite` de 1 a 1000, padrão 200. Ordem: mais recente primeiro.
- Resposta: `{"eventos": [...], "syslog_ativo": bool}`. `syslog_ativo` = chegou algum evento dessa MK nas últimas 24 h. Com isso, o painel diferencia "sem eventos no filtro" de "esta MK não está mandando log".

## Painel (Flutter)

- Cartão **Eventos** em `mk_detail.dart`, depois de Portas/IPs e antes do Histórico. Segue o padrão `_Carrega` de `widgets/inventario.dart` e os tokens do Trade UI. Os dois temas são obrigatórios.
- No topo: chips de tipo (Todos, Logins, Falhas de login, Configuração, Interfaces, IPsec, DHCP, PPPoE, Reboot, Erros), período (últimas 24 h / 7 dias / 30 dias), campo de busca e botão atualizar. Sem atualização automática nesta fase.
- Linha: hora local (`dd/MM HH:mm:ss`, `tabular-nums`), selo do tipo e mensagem. `login_falha` e `erro` aparecem em `negative`, e `login` e `config` em `info`. Até 200 linhas, com "mostrar mais" pedindo o próximo bloco (`ate=` igual à hora do último).
- Com `syslog_ativo=false` e sem eventos: um aviso "Esta MK não está mandando eventos", com o botão **Ligar eventos** abrindo o script curto desta MK para copiar.

## Configuração na MK (Preparar MK)

- **O `src-address` sai do cadastro, não da descoberta.** O `ip_tunel` cadastrado é o que o receptor usa para identificar a MK, então é ele que vai na MK. Chamada do designer:
  - **Script curto "Ligar eventos" por MK:** fica no detail da MK (botão no cartão Eventos), gerado no Flutter a partir do `ip_tunel` da MK. O `NODEBEAT_IP_ORIGEM` vem do `/api/preparar-mk` que já existe. Esse é o caminho das ~20 MKs em produção, que não podem rodar o script completo de novo (ele troca a senha do `monitor`).
  - **Script completo do Preparar MK:** ganha o mesmo passo, mas só quando a descoberta achou **exatamente um** IP de túnel. Com zero ou vários, pula o passo e imprime "eventos não ligados: use Ligar eventos no detalhe da MK depois do cadastro". O passo é idempotente: remove as configurações anteriores pelo nome e recria.
- Conteúdo validado no spike, um por versão. O script escolhe pela versão da MK e roda tudo num bloco `{}` só:

```
/system logging action remove [find where name="nodebeat"]
# v6:
/system logging action add name=nodebeat target=remote remote=$ipOrigem remote-port=514 src-address=$ipTunel bsd-syslog=no
# v7 (a v6 rejeita o parâmetro ao ler o script, por isso vai via [:parse "..."]):
/system logging action add name=nodebeat target=remote remote=$ipOrigem remote-port=514 src-address=$ipTunel remote-log-format=default
/system logging remove [find where action="nodebeat"]
:foreach t in={"account,!debug";"system,!debug";"interface,!debug";"ipsec,!debug";"dhcp,!debug";"pppoe,!debug";"critical";"error"} do={
  /system logging add topics=$t action=nodebeat
}
```

  - **Versão:** `[:tonum [:pick $ver 0 [:find $ver "."]]] >= 7`, com `$ver` = `[/system resource get version]`, como o Preparar MK já faz.
  - `$ipOrigem` = `NODEBEAT_IP_ORIGEM` (já existe). `$ipTunel` = o `ip_tunel` cadastrado (script curto) ou o único IP descoberto (script completo).
  - `/system logging` não aceita `comment` em todas as versões, por isso a limpeza é por `action="nodebeat"`.
- Testes do `mk_script.dart` cobrem o passo novo e o script curto, no mesmo estilo dos atuais.

## Deploy

- `deploy/compose.yml`: serviço `syslog` (`command: ["python", "-m", "nodebeat.syslog"]`, `cap_drop: [ALL]`, `ports: ["${NODEBEAT_SYSLOG_BIND_IP:?}:514:5514/udp"]`, `depends_on` mongo e redis healthy, `environment: *env`).
- Env novas: `NODEBEAT_SYSLOG_BIND_IP` (no CT: o IP da eth1, <IP_NODEBEAT_TUNEL>, só no `.env`) e `NODEBEAT_SYSLOG_DIAS` (padrão 30). `.env.example` e `deploy/README.md` ganham as duas, com placeholders.
- `config.Settings` ganha `syslog_dias: int = 30`.
- O `rotas-tunel.sh` não muda: ele cuida da saída, e aqui o tráfego é de entrada.
- IP fixo do `syslog` na rede do compose: `networks: default: ipv4_address: 172.30.0.50`. Depois de `up`, rodar `conntrack -D -p udp --dport 514` no CT (README).

## Testes

- `test_eventos.py`: parser e classificação com as amostras reais do spike, linha sem tópicos, UTF-8 inválido e linha gigante.
- `test_syslog.py`: receptor com socket UDP real em `127.0.0.1` e porta efêmera, Mongo `mongomock-motor`. Cobre IP desconhecido descartado, IP cadastrado gravado, limite por MK e teto da fila.
- `test_api_eventos.py`: filtros, `limite`, 404, `syslog_ativo` e exigência de sessão.
- Flutter: `eventos_test.dart` (chips filtram, aviso de syslog inativo, temas claro e escuro).

## Riscos aceitos

- **Falsificação:** UDP sem autenticação, então quem está na LAN de um condomínio pode forjar um pacote com o IP da MK. Isso é aceito numa rede interna atrás do IPsec. Os eventos são indício, não prova.
- **Perda:** UDP pode perder pacotes, e evento perdido não volta. Isso é aceito, e TCP/TLS fica para depois, se fizer falta.

## Para o construtor decidir

- Nomes internos, a organização das regex e o texto exato dos chips e avisos.
- Se o lote grava a cada 1 s ou a cada 500 eventos (o que vier primeiro), ou só por tempo.

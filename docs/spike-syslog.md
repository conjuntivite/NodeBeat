# Spike — syslog das MKs até o NodeBeat (2026-11-18)

MKs de teste: uma v6.49.17 e uma v7.24. CT do NodeBeat com o receptor na eth1 (IP coberto pelos IPsec).

## Resultados

| Pergunta | Resultado |
|---|---|
| O pacote chega pelo IPsec com `src-address` = IP da LAN da MK? | **Sim**, nas duas, sem regra nova no SonicWall |
| `rp_filter` atrapalha? | **Não**: `all=2` (frouxo) já no CT, e o kernel usa o maior valor entre `all` e a interface |
| O Docker preserva o IP de origem? | **Sim**, pelo DNAT. **Mas** fluxos UDP antigos na tabela conntrack continuam indo para o destino anterior (o docker-proxy, que troca a origem pelo gateway do Docker). A MK manda sem parar, então o fluxo nunca expira. A correção é `conntrack -D -p udp --dport 514` depois de subir ou recriar o serviço, mais um IP fixo do container no compose |
| Formato com cabeçalho (v6 `bsd-syslog=yes`, v7 `remote-log-format=syslog`) | Ruim: o nome (identity) da MK tem espaços, então não dá para separar o nome da mensagem. A v6 não manda os tópicos |
| Formato padrão (v6 `bsd-syslog=no`, v7 `remote-log-format=default`) | **Escolhido.** As duas versões mandam só `topicos mensagem`, sem PRI, sem hora e sem nome da MK |
| v7: `bsd-syslog` existe? | **Não** (só na v6). Na v7 o equivalente é `remote-log-format`. O script precisa escolher pela versão |
| Tópicos sem `!debug` | Inundação: ~2 000 linhas em 3 min de `ipsec,debug,packet` e `pppoe,ppp,debug,packet`. Com `<topico>,!debug`, some |
| Ruído do próprio NodeBeat | O usuário `monitor` entra e sai pela API a cada 30 s em cada MK (≈ 2 880 linhas/dia por MK). O receptor deve descartar |
| Mensagem de configuração | v6: `log rule added by admin`. v7: `log rule added by tcp-msg(winbox):admin@<ip>/terminal (*9 = /system logging add ...)` |

As amostras (anonimizadas) estão em `backend/tests/amostras_syslog.txt`.

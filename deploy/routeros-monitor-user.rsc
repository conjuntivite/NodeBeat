# Usuario read-only "monitor" + api-ssl. Aplicado MANUALMENTE pelo humano (v6 e v7).
# Preencha antes de aplicar (substitua nas linhas abaixo; nao ha IPs fixos no arquivo):
#   <IP_VM>            IP de origem permitido na API (spike: <IP_PUBLICO_SEDE>; depois: IP do tunel da VM)
#   <IP_PUBLICO_SEDE>  IP de origem permitido para ICMP (spike: <IP_PUBLICO_SEDE>)
#   <SENHA_MONITOR>    senha do usuario monitor
#   <WAN_IFACE>        nome da interface WAN (ex.: ether1 ou pppoe-out1)
# Re-executar falha em nomes ja existentes (certificado, grupo, usuario): remova antes ou rode so o que falta.
# Evite "$" dentro de strings: RouterOS interpreta como variavel.
# v6 x v7: sintaxe abaixo funciona nas duas. Na v7 "sign" aceita as mesmas opcoes; na v6 o "sign"
# bloqueia ate terminar (pode levar alguns segundos); na v7 pode retornar antes -> o :delay cobre.

/certificate add name=monitor-api common-name=monitor-api days-valid=3650 key-usage=tls-server
/certificate sign monitor-api
:delay 5s

/ip service set api-ssl certificate=monitor-api address=<IP_VM> disabled=no

/user group add name=monitor policy=read,api,!write,!policy,!ssh,!ftp,!winbox,!telnet,!web,!sensitive
/user add name=monitor group=monitor password="<SENHA_MONITOR>" address=<IP_VM>

# ICMP: place-before=0 poe a regra no topo da chain input, antes de qualquer drop.
/ip firewall filter add chain=input protocol=icmp in-interface=<WAN_IFACE> src-address=<IP_PUBLICO_SEDE> action=accept place-before=0 comment="monitor-icmp"
# Spike: se o firewall bloquear 8729 no WAN, adicione tambem (mesmo place-before=0):
# /ip firewall filter add chain=input protocol=tcp dst-port=8729 in-interface=<WAN_IFACE> src-address=<IP_VM> action=accept place-before=0 comment="monitor-api-ssl"

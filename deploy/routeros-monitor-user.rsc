# Usuario read-only "monitor" + api-ssl. Aplicado MANUALMENTE pelo humano (v6 e v7).
# Preencha antes de aplicar (substitua nas linhas abaixo; nao ha IPs fixos no arquivo):
#   <IP_VM>            IP de origem permitido na API (spike: <IP_PUBLICO_SEDE>; depois: IP do tunel da VM)
#   <IP_PUBLICO_SEDE>  IP de origem permitido para ICMP (spike: <IP_PUBLICO_SEDE>)
#   <SENHA_MONITOR>    senha do usuario monitor; SO ASCII alfanumerico (sem $, aspas ou barra invertida), pois fica entre aspas no .rsc e o librouteros exige ASCII
#   <WAN_IFACE>        nome da interface WAN (ex.: ether1, pppoe-out1 ou "PPPoE - ALT"; pode ter espacos, por isso vai entre aspas nas linhas abaixo)
# Re-executar falha em nomes ja existentes (certificado, grupo, usuario): remova antes ou rode so o que falta.
# Evite "$" dentro de strings: RouterOS interpreta como variavel.
# v6 x v7: sintaxe abaixo testada nas duas (6.49.17 e 7.24.4). Na v6 o "sign" bloqueia ate terminar
# (pode levar alguns segundos); na v7 pode retornar antes -> o :delay cobre.
# Na v6, "/certificate sign monitor-api" sem CA falha com "CA not found": por isso a CA propria abaixo.

/certificate add name=monitor-ca common-name=monitor-ca days-valid=3650 key-usage=key-cert-sign,crl-sign
/certificate sign monitor-ca
:delay 5s
/certificate add name=monitor-api common-name=monitor-api days-valid=3650 key-usage=tls-server
/certificate sign monitor-api ca=monitor-ca
:delay 5s

# "address=" na v7.24 funciona mas avisa "Deprecation warning" (novo nome: available-from); a v6 so conhece "address".
# Mantido "address=" porque funciona nas duas hoje; trocar para available-from quando a v6 sair de uso.
/ip service set api-ssl certificate=monitor-api address=<IP_VM>/32 disabled=no

/user group add name=monitor policy=read,api,!write,!policy,!ssh,!ftp,!winbox,!telnet,!web,!sensitive
/user add name=monitor group=monitor password="<SENHA_MONITOR>" address=<IP_VM>/32

# ICMP: place-before=0 poe a regra no topo da chain input, antes de qualquer drop.
# No spike a chain input das duas MKs nao tinha drop ativo, entao esta regra nao muda nada hoje;
# fica no script porque sera necessaria quando a chain input for endurecida.
/ip firewall filter add chain=input protocol=icmp in-interface="<WAN_IFACE>" src-address=<IP_PUBLICO_SEDE>/32 action=accept place-before=0 comment="monitor-icmp"
# Spike: se o firewall bloquear 8729 no WAN, adicione tambem (mesmo place-before=0):
# /ip firewall filter add chain=input protocol=tcp dst-port=8729 in-interface="<WAN_IFACE>" src-address=<IP_VM>/32 action=accept place-before=0 comment="monitor-api-ssl"

# Rollback (cole no terminal para desfazer tudo):
# /ip firewall filter remove [find comment="monitor-icmp"]
# /user remove monitor
# /user group remove monitor
# /ip service set api-ssl disabled=yes certificate=none address=""
# /certificate remove monitor-api
# /certificate remove monitor-ca

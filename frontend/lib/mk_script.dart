// Scripts RouterOS da página "Preparar MK". Montados no navegador; a senha nunca vai ao servidor.
import 'dart:math';

const _alfabeto = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/// 20 letras/números: o terminal da MK não aceita `$`, aspas nem acento dentro da string.
String gerarSenha([Random? rng]) {
  final r = rng ?? Random.secure();
  return String.fromCharCodes(List.generate(20, (_) => _alfabeto.codeUnitAt(r.nextInt(_alfabeto.length))));
}

/// Cole inteiro no terminal da MK (Winbox → New Terminal). Um bloco `{}` só: sem ele as `:local` somem a cada linha.
/// Só ASCII. Tudo que pode falhar é checado antes da primeira alteração (`:error` aborta o bloco).
/// [ipsSede]: todas as saídas públicas da sede (load balance), liberadas para ping numa address-list.
String scriptPreparar({required String ipOrigem, required List<String> ipsSede, required String senha}) => _modelo
    .replaceAll('@EVENTOS@', _eventos.replaceAll('@DST@', _dstPreparar))
    .replaceAll('@TRAVA_WAN@', _travaWan)
    .replaceAll('@NAT_MOVE@', _natMove)
    .replaceAll('@WINBOX_ALT@', _winboxAlt)
    .replaceAll('@LISTA_API@', _lista(ipOrigem, ipsSede))
    .replaceAll('@IP_ORIGEM@', ipOrigem)
    .replaceAll('@SEDE_LISTA@',
        ipsSede.map((ip) => '/ip firewall address-list add list=nodebeat-sede address=$ip comment="NodeBeat"').join('\n'))
    .replaceAll('@SENHA@', senha);

/// MK já cadastrada: liga só o envio de log (syslog) para o NodeBeat. Não mexe em usuário, certificado, api-ssl nem filtros.
String scriptLigarEventos({required String ipOrigem, required String ipTunel}) => '''{
${_eventos.replaceAll('@DST@', '"remote=$ipOrigem remote-port=514 src-address=$ipTunel"')}}
''';

/// No Preparar o IP de origem e o do túnel já são variáveis da MK.
const _dstPreparar = r'("remote=" . $ipOrigem . " remote-port=514 src-address=" . $ipTunel)';

/// Passo de eventos, colado dentro de um bloco `{}`. Idempotente.
/// Só a v7 aceita remote-log-format e só a v6 aceita bsd-syslog; a MK lê o bloco inteiro antes de rodar e rejeita parâmetro
/// desconhecido, por isso as duas formas ficam dentro de :parse e a escolha é por tentativa (:do/on-error), não por versão.
const _eventos = r''':local dst @DST@
/system logging remove [find where action="nodebeat"]
/system logging action remove [find where name="nodebeat"]
:do {
  [[:parse ("/system logging action add name=nodebeat target=remote " . $dst . " remote-log-format=default")]]
} on-error={
  [[:parse ("/system logging action add name=nodebeat target=remote " . $dst . " bsd-syslog=no")]]
}
:foreach t in={"account,!debug";"system,!debug";"interface,!debug";"ipsec,!debug"} do={
  /system logging add topics=$t action=nodebeat
}
:foreach t in={"dhcp,!debug";"pppoe,!debug";"critical";"error"} do={
  /system logging add topics=$t action=nodebeat
}
''';

/// `:local lista` com o NodeBeat e as saídas da sede (/32), em linhas curtas: a cópia do terminal quebra linha longa.
String _lista(String ipOrigem, List<String> ipsSede) => [
      ':local lista "$ipOrigem/32"',
      for (final ip in ipsSede) ':set lista (\$lista . ",$ip/32")',
    ].join('\n');

/// Regra que deixa a sede (lista nodebeat-sede) chegar na api-ssl pela WAN. Criada desligada e só ligada no lugar certo:
/// antes da monitor-icmp, senão antes da primeira regra input, senão no fim. Linhas de até 80 colunas.
const _travaWan = r'''/ip firewall filter remove [find where comment="monitor-api-wan"]
:local antes [/ip firewall filter find where comment="monitor-icmp"]
:if ([:len $antes] = 0) do={
  :set antes [/ip firewall filter find where chain=input && !dynamic]
}
:local f [/ip firewall filter add chain=input disabled=yes]
/ip firewall filter set $f protocol=tcp dst-port=8729 action=accept
/ip firewall filter set $f src-address-list=nodebeat-sede
/ip firewall filter set $f comment=monitor-api-wan
:if ([:len $antes] > 0) do={
  /ip firewall filter move $f destination=[:pick $antes 0]
}
/ip firewall filter set $f disabled=no''';

/// Operadora que bloqueia a 8729 na entrada: o NodeBeat tenta a 18729 pelo IP público, e esta regra a leva à 8729.
/// Sem a WAN (script curto) vale em qualquer interface; dst-address-type=local limita ao tráfego para a própria MK.
/// Vai para o topo do dstnat: um port forward amplo (DVR "em DMZ", faixa de portas) pegaria a 18729 antes.
/// O comentário já entra no add: se o bloco parar no meio, a regra continua achável pelo remove e pelo Desfazer.
const _natAlt = r'''/ip firewall nat remove [find where comment="monitor-api-alt"]
:local d [/ip firewall nat find where chain=dstnat && !dynamic]
:local alt [/ip firewall nat add chain=dstnat comment=monitor-api-alt]
/ip firewall nat set $alt protocol=tcp dst-port=18729
/ip firewall nat set $alt dst-address-type=local
/ip firewall nat set $alt action=redirect to-ports=8729
''' + _natMove;

const _natMove = r''':if ([:len $d] > 0) do={
  /ip firewall nat move $alt destination=[:pick $d 0]
}''';

/// Só no Preparar (MK nova). Operadoras bloqueiam a 8291: a 18291 da WAN é levada à 8291, e o Winbox continua na 8291
/// (nada muda para quem já entra por ela, e a sessão não cai). O filtro aceita só a 8291 que veio desse NAT, de qualquer
/// IP, por decisão do usuário até a etapa de segurança. As duas regras vão para o topo (MK que descarta tudo na entrada).
const _winboxAlt = r'''/ip firewall nat remove [find where comment="winbox-alt"]
:local wnd [/ip firewall nat find where chain=dstnat && !dynamic]
:local wn [/ip firewall nat add chain=dstnat in-interface=$wan protocol=tcp dst-port=18291 dst-address-type=local action=redirect to-ports=8291 comment="winbox-alt"]
:if ([:len $wnd] > 0) do={/ip firewall nat move $wn destination=[:pick $wnd 0]}
/ip firewall filter remove [find where comment="winbox-alt"]
:local wd [/ip firewall filter find where chain=input && !dynamic]
:local w [/ip firewall filter add chain=input disabled=yes comment=winbox-alt]
/ip firewall filter set $w protocol=tcp dst-port=8291 connection-nat-state=dstnat action=accept
:if ([:len $wd] > 0) do={
  /ip firewall filter move $w destination=[:pick $wd 0]
}
/ip firewall filter set $w disabled=no''';

/// MK já cadastrada: libera o botão Reiniciar do painel, pelo túnel e pelo IP público (o painel cai no IP público quando
/// o túnel não responde). Dá a permissão de reboot ao grupo monitor e abre as três travas da api-ssl para o NodeBeat e os
/// IPs da sede: serviço, usuário monitor (sem trocar a senha) e firewall.
/// available-from só existe a partir da 7.24 (e nunca na v6): tenta e, se a MK recusar, usa address.
String scriptLiberarReinicio({required String ipOrigem, required List<String> ipsSede}) => '''{
:if ([:len [/user find where name="monitor"]] = 0) do={
  :error "Usuario monitor nao existe: rode o Preparar MK primeiro"
}
/user group set monitor policy=read,api,reboot
${_lista(ipOrigem, ipsSede)}
:do {
  [[:parse ("/ip service set api-ssl available-from=" . \$lista)]]
} on-error={
  /ip service set api-ssl address=\$lista
}
/user set monitor address=\$lista
/ip firewall address-list remove [find where list="nodebeat-sede"]
${ipsSede.map((ip) => '/ip firewall address-list add list=nodebeat-sede address=$ip').join('\n')}
$_travaWan
$_natAlt
:put "OK. Reiniciar liberado pelo tunel e pelo IP publico (lista nodebeat-sede)"
}
''';


const scriptDesfazer = r'''/ip firewall filter remove [find where comment="winbox-alt"]
/ip firewall nat remove [find where comment="winbox-alt"]
/ip firewall nat remove [find where comment="monitor-api-alt"]
/ip firewall filter remove [find where comment="monitor-icmp"]
/ip firewall filter remove [find where comment="monitor-api"]
/ip firewall filter remove [find where comment="monitor-api-wan"]
/ip firewall address-list remove [find where list="nodebeat-sede"]
/user remove [find where name="monitor"]
/user group remove [find where name="monitor"]
/ip service set api-ssl disabled=yes certificate=none
/certificate remove [find where name="monitor-api"]
/certificate remove [find where name="monitor-ca"]
/system logging remove [find where action="nodebeat"]
/system logging action remove [find where name="nodebeat"]''';

const _modelo = r'''{
:local ipOrigem "@IP_ORIGEM@"
:local senha "@SENHA@"

# 1) Descobrir. Nada e alterado ate o passo 2.
:local ver [/system resource get version]
:local p1 [:find $ver "."]
:local maior [:tonum [:pick $ver 0 $p1]]
:local resto [:pick $ver ($p1 + 1) [:len $ver]]
:local menor 0
:local i 0
:while ($i < [:len $resto] && [:typeof [:find "0123456789" [:pick $resto $i]]] = "num") do={
  :set menor ($menor * 10 + [:tonum [:pick $resto $i]])
  :set i ($i + 1)
}
:local novo (($maior > 7) || ($maior = 7 && $menor >= 24))

:local rotas [/ip route find where dst-address=0.0.0.0/0 && active]
:if ([:len $rotas] = 0) do={:error "Sem rota padrao ativa: nao deu para descobrir a WAN. Nada foi alterado."}
:if ([:len $rotas] > 1) do={:error "Mais de uma rota padrao ativa (duas WANs): nao deu para escolher a WAN. Nada foi alterado."}
:local rota [:pick $rotas 0]
:local wan ""
# gateway que ja e uma interface (PPPoE, inclusive com espaco no nome) vale inteiro;
# a rota pode ter varios gateways (ex.: pppoe-out1,*7): vale o primeiro que for interface existente
:foreach g in=[/ip route get $rota gateway] do={
  :local gw [:tostr $g]
  :local pg [:find $gw "%"]
  :if ([:typeof $pg] = "num") do={:set gw [:pick $gw ($pg + 1) [:len $gw]]}
  :if ([:len $wan] = 0 && [:len [/interface find where name=$gw]] > 0) do={:set wan $gw}
}
# gateway por IP: a interface vem de immediate-gw (v7) ou gateway-status (v6)
:if ([:len $wan] = 0) do={
  :if ($maior >= 7) do={
    :local ig [:tostr [/ip route get $rota immediate-gw]]
    :local p [:find $ig "%"]
    :if ([:typeof $p] = "num") do={:set wan [:pick $ig ($p + 1) [:len $ig]]} else={:set wan $ig}
  } else={
    :local gs [:tostr [/ip route get $rota gateway-status]]
    :local p [:find $gs "via "]
    :if ([:typeof $p] = "num") do={:set wan [:pick $gs ($p + 4) [:len $gs]]}
  }
}
:while ([:pick $wan 0 1] = " ") do={:set wan [:pick $wan 1 [:len $wan]]}
:if ([:len [/interface find where name=$wan]] = 0) do={:error ("WAN nao reconhecida (\"" . $wan . "\"). Nada foi alterado.")}

:local ipPub "nao encontrado"
:foreach a in=[/ip address find where interface=$wan] do={
  :local s [/ip address get $a address]
  :set ipPub [:pick $s 0 [:find $s "/"]]
}
:local ipTunel ""
:foreach pol in=[/ip ipsec policy find where !template] do={
  :do {
    :local src [/ip ipsec policy get $pol src-address]
    :if ([:tostr $src] != "0.0.0.0/0") do={
      :foreach a in=[/ip address find where interface!=$wan] do={
        :local s [/ip address get $a address]
        :local ip [:toip [:pick $s 0 [:find $s "/"]]]
        :if (($ip in $src) && [:typeof [:find $ipTunel [:tostr $ip]]] != "num") do={
          :if ([:len $ipTunel] > 0) do={:set ipTunel ($ipTunel . ", ")}
          :set ipTunel ($ipTunel . [:tostr $ip])
        }
      }
    }
  } on-error={}
}
:if ([:len $ipTunel] = 0) do={:set ipTunel "nao encontrado (veja /ip ipsec policy e /ip address)"}
# sem nenhuma politica IPsec: MK sem VPN, o NodeBeat acessa pelo IP publico
:local semIpsec ([:len [/ip ipsec policy find where !template]] = 0)

# monitor de outra ferramenta (Dude, Zabbix...): nao tomar posse.
:local u [/user find where name="monitor"]
:if ([:len $u] > 0) do={
  :if ([/user get [:pick $u 0] group] != "monitor") do={:error "Ja existe um usuario monitor em outro grupo (outra ferramenta). Nada foi alterado."}
}
:foreach x in=[/user find where group="monitor" && name!="monitor"] do={
  :error ("O grupo monitor tem outro usuario (" . [/user get $x name] . "), provavelmente de outra ferramenta. Nada foi alterado.")
}

:put ""
:put ("RouterOS " . $ver . " | WAN " . $wan)
:put "Cadastro no NodeBeat:"
:if ($semIpsec) do={
  :put "  MK SEM IPSEC (sem VPN): marque 'Sem IPsec' no cadastro"
  :put "  IP do tunel:  (nao se aplica)"
} else={
  :put ("  IP do tunel:  " . $ipTunel)
}
:put ("  IP publico:   " . $ipPub)
:put "  Usuario:      monitor"
:put ("  Senha:        " . $senha)

# 2) Aplicar.
:if ([:len [/certificate find where name="monitor-ca"]] = 0) do={
  /certificate add name=monitor-ca common-name=monitor-ca days-valid=3650 key-usage=key-cert-sign,crl-sign
  /certificate sign monitor-ca
}
:local n 0
:while ([:len [/certificate find where name="monitor-ca" && private-key]] = 0) do={
  :if ($n >= 30) do={:error "Certificado monitor-ca nao ficou pronto em 30 s. Rode o Desfazer da pagina e depois este script de novo."}
  :delay 1s
  :set n ($n + 1)
}
:if ([:len [/certificate find where name="monitor-api"]] = 0) do={
  /certificate add name=monitor-api common-name=monitor-api days-valid=3650 key-usage=tls-server
  /certificate sign monitor-api ca=monitor-ca
}
:set n 0
:while ([:len [/certificate find where name="monitor-api" && private-key]] = 0) do={
  :if ($n >= 30) do={:error "Certificado monitor-api nao ficou pronto em 30 s. Rode o Desfazer da pagina e depois este script de novo."}
  :delay 1s
  :set n ($n + 1)
}

# api-ssl e usuario monitor aceitam o NodeBeat (tunel) e as saidas da sede (IP publico, para o Reiniciar)
@LISTA_API@
:if ($novo) do={
  [[:parse ("/ip service set api-ssl certificate=monitor-api disabled=no available-from=" . $lista)]]
} else={
  /ip service set api-ssl certificate=monitor-api disabled=no address=$lista
}

:if ([:len [/user group find where name="monitor"]] = 0) do={
  /user group add name=monitor policy=read,api,reboot
} else={
  /user group set monitor policy=read,api,reboot
}
:local trocou false
:if ([:len [/user find where name="monitor"]] = 0) do={
  /user add name=monitor group=monitor password=$senha address=$lista
} else={
  /user set monitor group=monitor password=$senha address=$lista
  :set trocou true
}

/ip firewall address-list remove [find where list="nodebeat-sede"]
@SEDE_LISTA@
/ip firewall filter remove [find where comment="monitor-icmp"]
:local alvo [/ip firewall filter find where chain=input && !dynamic]
:if ([:len $alvo] > 0) do={
  /ip firewall filter add chain=input protocol=icmp in-interface=$wan src-address-list=nodebeat-sede action=accept place-before=[:pick $alvo 0] comment="monitor-icmp"
} else={
  /ip firewall filter add chain=input protocol=icmp in-interface=$wan src-address-list=nodebeat-sede action=accept comment="monitor-icmp"
}
# firewall que bloqueia a WAN derruba a api-ssl que chega pelo tunel: libera so o NodeBeat, so via IPsec
/ip firewall filter remove [find where comment="monitor-api"]
:if (!$semIpsec) do={
  /ip firewall filter add chain=input protocol=tcp dst-port=8729 src-address=$ipOrigem ipsec-policy=in,ipsec action=accept place-before=[find where comment="monitor-icmp"] comment="monitor-api"
}
# a sede tambem chega na api-ssl pela WAN (botao Reiniciar com o tunel caido)
@TRAVA_WAN@
# operadora que bloqueia a 8729: o NodeBeat tenta a 18729 pelo IP publico e esta regra leva a 8729
/ip firewall nat remove [find where comment="monitor-api-alt"]
:local d [/ip firewall nat find where chain=dstnat && !dynamic]
:local alt [/ip firewall nat add chain=dstnat in-interface=$wan protocol=tcp dst-port=18729 dst-address-type=local action=redirect to-ports=8729 comment="monitor-api-alt"]
@NAT_MOVE@
@WINBOX_ALT@

# eventos (syslog): so com um IP de tunel unico; a descoberta pode juntar varios ou dizer "nao encontrado"
:do {
:if ($semIpsec) do={
  :put "Eventos nao ligados: MK sem IPsec (o syslog so vai pelo tunel)"
} else={
:if ([:typeof [:toip $ipTunel]] = "ip") do={
@EVENTOS@} else={
  :put "Eventos nao ligados: use Ligar eventos no detalhe da MK depois do cadastro"
}
}
} on-error={:put "Eventos nao ligados: use Ligar eventos no detalhe da MK depois do cadastro"}

# 3) Resultado.
:local modo "address"
:if ($novo) do={:set modo "available-from"}
:put ""
:put ("OK. API-SSL (" . $modo . ") liberada para " . $ipOrigem . " e para a lista nodebeat-sede | ping liberado para a lista nodebeat-sede")
:if ($trocou) do={:put "ATENCAO: o usuario monitor ja existia e a senha foi trocada. Se a MK ja esta no NodeBeat, atualize a senha no cadastro (Editar)."}
:put "Winbox: porta 8291, ou 18291 pelo IP publico se a operadora bloquear a 8291"
}
'''; // a linha em branco no fim é o Enter: o terminal só executa o bloco quando recebe a "}" com Enter

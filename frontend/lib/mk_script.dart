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

/// MK já cadastrada: só libera o botão "Reiniciar" do painel.
const scriptLiberarReinicio = '/user group set monitor policy=read,api,reboot';

const scriptDesfazer = r'''/ip firewall filter remove [find where comment="monitor-icmp"]
/ip firewall filter remove [find where comment="monitor-api"]
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
:put ("  IP do tunel:  " . $ipTunel)
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

:if ($novo) do={
  [[:parse ("/ip service set api-ssl certificate=monitor-api disabled=no available-from=" . $ipOrigem . "/32")]]
} else={
  /ip service set api-ssl certificate=monitor-api disabled=no address=($ipOrigem . "/32")
}

:if ([:len [/user group find where name="monitor"]] = 0) do={
  /user group add name=monitor policy=read,api,reboot
} else={
  /user group set monitor policy=read,api,reboot
}
:local trocou false
:if ([:len [/user find where name="monitor"]] = 0) do={
  /user add name=monitor group=monitor password=$senha address=($ipOrigem . "/32")
} else={
  /user set monitor group=monitor password=$senha address=($ipOrigem . "/32")
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
/ip firewall filter add chain=input protocol=tcp dst-port=8729 src-address=$ipOrigem ipsec-policy=in,ipsec action=accept place-before=[find where comment="monitor-icmp"] comment="monitor-api"

# eventos (syslog): so com um IP de tunel unico; a descoberta pode juntar varios ou dizer "nao encontrado"
:do {
:if ([:typeof [:toip $ipTunel]] = "ip") do={
@EVENTOS@} else={
  :put "Eventos nao ligados: use Ligar eventos no detalhe da MK depois do cadastro"
}
} on-error={:put "Eventos nao ligados: use Ligar eventos no detalhe da MK depois do cadastro"}

# 3) Resultado.
:local modo "address"
:if ($novo) do={:set modo "available-from"}
:put ""
:put ("OK. API-SSL (" . $modo . ") liberada so para " . $ipOrigem . " | ping liberado para a lista nodebeat-sede")
:if ($trocou) do={:put "ATENCAO: o usuario monitor ja existia e a senha foi trocada. Se a MK ja esta no NodeBeat, atualize a senha no cadastro (Editar)."}
}
'''; // a linha em branco no fim é o Enter: o terminal só executa o bloco quando recebe a "}" com Enter

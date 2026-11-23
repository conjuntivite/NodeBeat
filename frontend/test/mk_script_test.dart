import 'package:flutter_test/flutter_test.dart';
import 'package:nodebeat/mk_script.dart';

void main() {
  final s = scriptPreparar(ipOrigem: '10.9.9.9', ipsSede: ['203.0.113.5', '198.51.100.7'], senha: 'Abc123xyz');

  test('senha: 20 letras/números e muda a cada chamada', () {
    final a = gerarSenha(), b = gerarSenha();
    expect(a, matches(RegExp(r'^[A-Za-z0-9]{20}$')));
    expect(a, isNot(b));
  });

  test('valores entram no script e não sobra placeholder', () {
    expect(s, contains('"10.9.9.9"'));
    expect(s, contains('address=203.0.113.5 '));
    expect(s, contains('address=198.51.100.7 '));
    expect(s, contains('"Abc123xyz"'));
    expect(s, isNot(contains('@')));
  });

  test('detecta MK sem IPsec e orienta o cadastro sem VPN', () {
    expect(s, contains(r':local semIpsec ([:len [/ip ipsec policy find where !template]] = 0)'));
    expect(s, contains("marque 'Sem IPsec' no cadastro"));
    expect(s, contains(r':if (!$semIpsec) do={')); // a regra monitor-api (so via IPsec) nao entra
  });

  test('só ASCII (terminal da MK)', () {
    expect(s.codeUnits.every((c) => c <= 0x7f), isTrue);
    expect(scriptDesfazer.codeUnits.every((c) => c <= 0x7f), isTrue);
  });

  test('um bloco só, chaves balanceadas', () {
    expect(s.trimLeft().startsWith('{'), isTrue);
    expect(s.trimRight().endsWith('}'), isTrue);
    var n = 0;
    for (final c in s.split('')) {
      if (c == '{') n++;
      if (c == '}') n--;
      expect(n, greaterThanOrEqualTo(0));
    }
    expect(n, 0);
  });

  test('todas as checagens vêm antes da primeira alteração', () {
    final primeira = s.indexOf('/certificate add');
    expect(s.lastIndexOf('Nada foi alterado'), lessThan(primeira));
    // sem rota, duas rotas, WAN desconhecida, usuario monitor de outro grupo, grupo monitor com outro usuario
    expect(RegExp(':error').allMatches(s.substring(0, primeira)).length, 5);
  });

  test('available-from só dentro de :parse (a v6 rejeita ao ler o script)', () {
    for (final m in RegExp('available-from=').allMatches(s)) {
      final linha = s.substring(s.lastIndexOf('\n', m.start) + 1, m.start);
      expect(linha, contains('[:parse'));
    }
    expect(s, contains('address='));
  });

  test('WAN: v7 immediate-gw com %, v6 gateway-status com via, e confere a interface', () {
    expect(s, contains('immediate-gw'));
    expect(s, contains('gateway-status'));
    expect(s, contains('"%"'));
    expect(s, contains('"via "'));
    expect(s, contains('/interface find where name=\$wan'));
  });

  test('certificado existente é reaproveitado (pin do NodeBeat)', () {
    final i = s.indexOf('/certificate add name=monitor-api');
    final antes = s.substring(0, i);
    expect(antes.lastIndexOf(':if ([:len [/certificate find where name="monitor-api"]] = 0)'), greaterThan(-1));
  });

  test('chain input vazia: place-before só se houver regra', () {
    expect(s, contains(r':if ([:len $alvo] > 0)'));
  });

  test('grupo só com read, api e reboot; avisa senha trocada', () {
    expect(s, contains('policy=read,api,reboot'));
    expect(s, isNot(contains('write')));
    expect(s.toLowerCase(), contains('atualize a senha no cadastro'));
  });

  test('liberar reinício e desfazer', () {
    final r = scriptLiberarReinicio(ipOrigem: '192.0.2.53', ipsSede: ['203.0.113.10']);
    expect(r, contains('/user group set monitor policy=read,api,reboot'));
    expect(r.indexOf('policy=read,api,reboot'), greaterThan(r.indexOf(':error "Usuario monitor nao existe')));
    for (final x in ['monitor-icmp', '/user remove', '/user group remove', '/certificate remove', 'api-ssl disabled=yes']) {
      expect(scriptDesfazer, contains(x));
    }
  });

  test('mostra os dados do cadastro antes de alterar (se algo falhar depois, eles já saíram)', () {
    expect(s.indexOf('Cadastro no NodeBeat'), lessThan(s.indexOf('/certificate add')));
    expect(s, contains(r':put ("  Senha:        " . $senha)'));
  });

  test('ping liberado pela lista de IPs da sede', () {
    expect(s, contains('/ip firewall address-list remove [find where list="nodebeat-sede"]'));
    expect(s, contains('src-address-list=nodebeat-sede'));
    expect(scriptDesfazer, contains('list="nodebeat-sede"'));
  });

  test('firewall que bloqueia a WAN: libera a 8729 só para o NodeBeat via IPsec, no topo; Desfazer remove', () {
    expect(s, contains(r'/ip firewall filter remove [find where comment="monitor-api"]'));
    expect(
        s,
        contains(r'/ip firewall filter add chain=input protocol=tcp dst-port=8729 src-address=$ipOrigem '
            r'ipsec-policy=in,ipsec action=accept place-before=[find where comment="monitor-icmp"] comment="monitor-api"'));
    expect(s.indexOf('comment="monitor-api"'), greaterThan(s.indexOf('comment="monitor-icmp"\n')));
    expect(scriptDesfazer, contains('[find where comment="monitor-api"]'));
  });

  test('regra no topo: antes da 1a regra estática da input, sem índice fixo', () {
    expect(s, contains('chain=input && !dynamic'));
    expect(s, contains(r'place-before=[:pick $alvo 0]'));
    expect(s, isNot(contains('place-before=0')));
  });

  test('não toma um usuário/grupo monitor de outra ferramenta', () {
    expect(s, contains('outro grupo'));
    expect(s, contains('group="monitor" && name!="monitor"'));
  });

  test('IPsec 0.0.0.0/0 não conta para o IP do túnel; certificado travado manda desfazer', () {
    expect(s, contains('"0.0.0.0/0"'));
    expect(s, contains('Desfazer'));
  });

  test('terminal da MK: sem "?" (abre a ajuda até dentro de aspas) e termina com Enter', () {
    for (final x in [s, scriptDesfazer, scriptLiberarReinicio(ipOrigem: '192.0.2.53', ipsSede: ['203.0.113.10'])]) {
      expect(x, isNot(contains('?')));
    }
    expect(s.endsWith('}\n'), isTrue);
  });

  test('WAN com espaço no nome (ex.: "PPPoE - ALT"): gateway que já é interface vale inteiro', () {
    expect(s, contains(r'/interface find where name=$gw'));
    expect(s.indexOf(r'/interface find where name=$gw'), lessThan(s.indexOf('gateway-status')));
  });

  test('rota com vários gateways (ex.: "pppoe-out1,*7"): olha um a um, não a lista junta', () {
    expect(s, contains(r':foreach g in=[/ip route get $rota gateway] do={'));
    expect(s, isNot(contains(r'[:tostr [/ip route get $rota gateway]]')));
  });

  group('eventos (syslog)', () {
    final e = scriptLigarEventos(ipOrigem: '192.0.2.10', ipTunel: '10.9.0.1');

    test('ligar eventos: action, v7 dentro de :parse, 8 topics, sem firewall, ASCII', () {
      expect(e, contains('remote=192.0.2.10'));
      expect(e, contains('src-address=10.9.0.1'));
      expect(e, contains('remote-port=514'));
      expect(e, contains('bsd-syslog=no'));
      final m = RegExp('remote-log-format=default').firstMatch(e)!;
      expect(e.substring(e.lastIndexOf('\n', m.start) + 1, m.start), contains('[:parse'));
      for (final t in ['account', 'system', 'interface', 'ipsec', 'dhcp', 'pppoe']) {
        expect(e, contains('"$t,!debug"'));
      }
      expect(e, contains('"critical";"error"'));
      expect(e, isNot(contains('firewall')));
      expect(e, isNot(contains('@')));
      expect(e.codeUnits.every((c) => c < 128), isTrue);
      expect(e.endsWith('}\n'), isTrue);
    });

    test('preparar: passo de eventos entre monitor-api e Resultado, só com IP de túnel único', () {
      expect(s, contains('action="nodebeat"'));
      expect(s, contains(r'[:typeof [:toip $ipTunel]] = "ip"'));
      expect(s, contains('Eventos nao ligados'));
      expect(s, contains(':local ipOrigem "10.9.9.9"'));
      expect(s.indexOf('action="nodebeat"'), greaterThan(s.indexOf('comment="monitor-api"')));
      expect(s.indexOf('action="nodebeat"'), lessThan(s.indexOf('# 3) Resultado')));
      expect(s.codeUnits.every((c) => c < 128), isTrue);
    });

    test('bsd-syslog e remote-log-format só dentro de [:parse (, escolhidos por :do/on-error', () {
      for (final x in [e, s]) {
        for (final l in x.split('\n')) {
          if (l.contains('bsd-syslog') || l.contains('remote-log-format')) expect(l, contains('[:parse ('));
        }
        expect(x, contains(':do {\n  [[:parse ("/system logging action add'));
        expect(x, contains('} on-error={\n  [[:parse ("/system logging action add'));
      }
      expect(e, isNot(contains(r'$maior')));
    });

    test('preparar: passo de eventos dentro de :do com on-error (falha não aborta o script)', () {
      final i = s.indexOf(':do {\n:if (\$semIpsec)');
      final f = s.indexOf('} on-error={:put "Eventos nao ligados', i);
      expect(i, greaterThan(-1));
      expect(f, greaterThan(i));
      expect(s.indexOf('action="nodebeat"'), inInclusiveRange(i, f));
      expect(f, lessThan(s.indexOf('# 3) Resultado')));
    });

    test(':parse com a string entre parênteses (o "." só concatena dentro de expressão)', () {
      expect(e, contains('[[:parse ("/system logging action add'));
      expect(e, contains(r'target=remote " . $dst . " remote-log-format=default")]]'));
      expect(e, contains(r'target=remote " . $dst . " bsd-syslog=no")]]'));
      expect(e, contains(':local dst "remote=192.0.2.10 remote-port=514 src-address=10.9.0.1"'));
      expect(s, contains(r':local dst ("remote=" . $ipOrigem . " remote-port=514 src-address=" . $ipTunel)'));
      expect(s, contains(r'target=remote " . $dst . " remote-log-format=default")]]'));
      expect(s, contains('[[:parse ("/system logging action add'));
    });

    test('linhas curtas (terminal que quebra linha): nenhuma passa de 110 colunas', () {
      final ini = s.indexOf('# eventos (syslog)');
      final fim = s.indexOf('# 3) Resultado');
      for (final l in [...e.split('\n'), ...s.substring(ini, fim).split('\n')]) {
        expect(l.length, lessThanOrEqualTo(110), reason: l);
      }
    });

    test('forma exata validada numa MK v7.24', () {
      expect(e, '''{
:local dst "remote=192.0.2.10 remote-port=514 src-address=10.9.0.1"
/system logging remove [find where action="nodebeat"]
/system logging action remove [find where name="nodebeat"]
:do {
  [[:parse ("/system logging action add name=nodebeat target=remote " . \$dst . " remote-log-format=default")]]
} on-error={
  [[:parse ("/system logging action add name=nodebeat target=remote " . \$dst . " bsd-syslog=no")]]
}
:foreach t in={"account,!debug";"system,!debug";"interface,!debug";"ipsec,!debug"} do={
  /system logging add topics=\$t action=nodebeat
}
:foreach t in={"dhcp,!debug";"pppoe,!debug";"critical";"error"} do={
  /system logging add topics=\$t action=nodebeat
}
}
''');
    });

    test('desfazer remove regras e action nodebeat', () {
      expect(scriptDesfazer, contains('/system logging remove [find where action="nodebeat"]'));
      expect(scriptDesfazer, contains('/system logging action remove [find where name="nodebeat"]'));
    });
  });

  group('reinício pelo IP público', () {
    final curto = scriptLiberarReinicio(ipOrigem: '192.0.2.53', ipsSede: ['203.0.113.10', '203.0.113.11']);
    final completo = scriptPreparar(ipOrigem: '192.0.2.53', ipsSede: ['203.0.113.10', '203.0.113.11'], senha: 'Abc123');

    test('script curto libera as três travas para a sede', () {
      expect(curto, contains(':local lista "192.0.2.53/32"'));
      expect(curto, contains(':set lista (\$lista . ",203.0.113.10/32")'));
      expect(curto, contains(':set lista (\$lista . ",203.0.113.11/32")'));
      expect(curto, contains('[[:parse ("/ip service set api-ssl available-from=" . \$lista)]]'));
      expect(curto, contains('/ip service set api-ssl address=\$lista'));
      expect(curto, contains('/user set monitor address=\$lista'));
      expect(curto, contains('/ip firewall address-list remove [find where list="nodebeat-sede"]'));
      expect(curto, contains('/ip firewall address-list add list=nodebeat-sede address=203.0.113.10'));
      expect(curto, contains('/ip firewall address-list add list=nodebeat-sede address=203.0.113.11'));
      expect(curto, contains('dst-port=8729'));
      expect(curto, contains('src-address-list=nodebeat-sede'));
      expect(curto, contains('comment=monitor-api-wan'));
      expect(curto, isNot(contains('password')));
    });

    test('regra nova sem monitor-icmp cai na primeira regra input, ou fica no fim', () {
      expect(curto, contains(':local antes [/ip firewall filter find where comment="monitor-icmp"]'));
      expect(curto, contains(':set antes [/ip firewall filter find where chain=input && !dynamic]'));
      expect(curto, contains(':if ([:len \$antes] > 0) do={'));
    });

    test('script curto: bloco único, ASCII e linhas de até 80 colunas', () {
      expect(curto.trimLeft().startsWith('{'), isTrue);
      expect(curto.codeUnits.every((c) => c < 128), isTrue);
      for (final l in curto.split('\n')) {
        expect(l.length, lessThanOrEqualTo(80), reason: l);
      }
    });

    test('Preparar usa a lista no serviço, no usuário e cria monitor-api-wan', () {
      expect(completo, contains('available-from=" . \$lista)'));
      expect(completo, contains('address=\$lista'));
      expect(completo, contains('/user add name=monitor group=monitor password=\$senha address=\$lista'));
      expect(completo, contains('/user set monitor group=monitor password=\$senha address=\$lista'));
      expect(completo, contains('comment=monitor-api-wan'));
      expect(completo, isNot(contains('/32")]]')));
    });

    test('Preparar diz no fim que a sede também tem acesso', () {
      expect(completo, contains('liberada para " . \$ipOrigem . " e para a lista nodebeat-sede'));
      expect(completo, isNot(contains('liberada so para')));
    });

    test('script curto para antes de mexer se a MK não tem o usuário monitor', () {
      final guarda = curto.indexOf(':if ([:len [/user find where name="monitor"]] = 0) do={');
      expect(guarda, greaterThan(0));
      expect(curto, contains(':error "Usuario monitor nao existe: rode o Preparar MK primeiro"'));
      expect(guarda, lessThan(curto.indexOf('/ip service set api-ssl')));
    });

    test('Preparar cria o NAT 18729 -> 8729 na WAN, removendo o antigo antes', () {
      final rm = completo.indexOf('/ip firewall nat remove [find where comment="monitor-api-alt"]');
      final add = completo.indexOf('in-interface=\$wan protocol=tcp dst-port=18729');
      expect(rm, greaterThan(0));
      expect(add, greaterThan(rm));
      expect(completo, contains('dst-port=18729 dst-address-type=local action=redirect'));
    });

    test('script curto cria o NAT 18729 -> 8729 sem depender da WAN', () {
      final rm = curto.indexOf('/ip firewall nat remove [find where comment="monitor-api-alt"]');
      expect(rm, greaterThan(0));
      expect(curto.indexOf('dst-port=18729'), greaterThan(rm));
      expect(curto, contains('to-ports=8729'));
      expect(curto, contains('comment=monitor-api-alt'));
      expect(curto, isNot(contains('in-interface')));
      expect(curto, contains('dst-address-type=local'));
    });

    test('NAT 18729 vai para o topo do dstnat nos dois scripts (port forward amplo pegaria antes)', () {
      for (final sc in [completo, curto]) {
        expect(sc, contains('[/ip firewall nat find where chain=dstnat && !dynamic]'));
        expect(sc, contains(r'/ip firewall nat move $alt destination=[:pick $d 0]'));
      }
      expect(curto, contains('[/ip firewall nat add chain=dstnat comment=monitor-api-alt]'));
    });

    test('script curto (MK já cadastrada) não mexe no Winbox', () {
      expect(curto, isNot(contains('winbox')));
    });

    test('Preparar: NAT 18291 -> 8291 na WAN, no topo do dstnat, sem trocar a porta do Winbox', () {
      final rm = completo.indexOf('/ip firewall nat remove [find where comment="winbox-alt"]');
      expect(rm, greaterThan(0));
      expect(completo.indexOf(
          r'in-interface=$wan protocol=tcp dst-port=18291 dst-address-type=local action=redirect to-ports=8291'), greaterThan(rm));
      expect(completo, contains(r'/ip firewall nat move $wn destination=[:pick $wnd 0]'));
      expect(completo, isNot(contains('winbox port=')));
    });

    test('Preparar: filtro winbox-alt aceita só a 8291 que veio do NAT, no topo do input', () {
      expect(completo, contains('/ip firewall filter remove [find where comment="winbox-alt"]'));
      expect(completo, contains('protocol=tcp dst-port=8291 connection-nat-state=dstnat action=accept'));
      expect(completo, contains(r'/ip firewall filter move $w destination=[:pick $wd 0]'));
      expect(completo, contains(r'/ip firewall filter set $w disabled=no'));
      expect(completo, isNot(contains('dst-port=18291 action=accept')));
    });

    test('Desfazer remove o NAT e o filtro winbox-alt', () {
      expect(scriptDesfazer, contains('/ip firewall filter remove [find where comment="winbox-alt"]'));
      expect(scriptDesfazer, contains('/ip firewall nat remove [find where comment="winbox-alt"]'));
    });

    test('Desfazer remove o NAT monitor-api-alt', () {
      expect(scriptDesfazer, contains('/ip firewall nat remove [find where comment="monitor-api-alt"]'));
    });

    test('Desfazer remove monitor-api-wan', () {
      expect(scriptDesfazer, contains('/ip firewall filter remove [find where comment="monitor-api-wan"]'));
    });
  });
}

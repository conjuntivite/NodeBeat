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
    expect(scriptLiberarReinicio, '/user group set monitor policy=read,api,reboot');
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
    for (final x in [s, scriptDesfazer, scriptLiberarReinicio]) {
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
}

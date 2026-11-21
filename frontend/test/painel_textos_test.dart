import 'package:flutter_test/flutter_test.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/widgets/painel_textos.dart';

import 'painel_api_test.dart' show painelJson;

PainelEventos _painel({String acesso = 'esperado', int totalAcesso = 12, List<String> semaforos = const ['verde']}) {
  final j = painelJson();
  (j['resumo'] as Map)['acesso'] = totalAcesso;
  (j['resumo_estado'] as Map)['acesso'] = {'estado': acesso, 'delta_pct': 4};
  j['por_mk'] = [
    for (var i = 0; i < semaforos.length; i++)
      {'mk_id': 'm$i', 'nome': 'MK$i', 'semaforo': semaforos[i], 'motivos': <String>[], 'contagens': <String, int>{}},
  ];
  return PainelEventos.fromJson(j);
}

void main() {
  group('fraseSituacao', () {
    test('login de fora aceito', () {
      expect(fraseSituacao(_painel(acesso: 'critico')), startsWith('Atenção: houve login de fora aceito.'));
    });
    test('sem invasão, com MK em vermelho (singular e plural)', () {
      expect(fraseSituacao(_painel(semaforos: ['verde', 'vermelho'])), 'Sem invasão detectada, mas 1 MK em vermelho.');
      expect(fraseSituacao(_painel(semaforos: ['vermelho', 'vermelho'])), 'Sem invasão detectada, mas 2 MKs em vermelho.');
    });
    test('varredura constante é esperada', () {
      expect(fraseSituacao(_painel()), 'Sem invasão. A rede está sob varredura constante, o que é esperado.');
    });
    test('sem nenhum evento: tudo calmo', () {
      expect(fraseSituacao(_painel(totalAcesso: 0)), 'Tudo calmo.');
    });
  });

  test('rotuloEstado', () {
    expect([for (final e in ['esperado', 'normal', 'atencao', 'critico']) rotuloEstado(e)],
        ['Esperado', 'Normal', 'Atenção', 'Crítico']);
  });

  test('textoDelta: alta, queda e sem base', () {
    expect(textoDelta(4), '↗ +4% vs. média 7 dias');
    expect(textoDelta(-2), '↘ −2% vs. média 7 dias');
    expect(textoDelta(0), '→ 0% vs. média 7 dias');
    expect(textoDelta(null), '—');
  });

  group('notaConcentracao', () {
    test('a primeira MK com 25% ou mais do total gera a nota', () {
      final n = notaConcentracao([('Centro', 30), ('Norte', 40 + 30)]..sort((a, b) => b.$2.compareTo(a.$2)));
      expect(n, contains('Norte'));
      expect(n, contains('70%'));
      expect(n, contains('SSH/Winbox'));
    });
    test('abaixo de 25% ou lista vazia não gera nota', () {
      expect(notaConcentracao([('A', 20), ('B', 20), ('C', 20), ('D', 20), ('E', 20)]), isNull);
      expect(notaConcentracao([]), isNull);
      expect(notaConcentracao([('A', 0)]), isNull);
    });
  });

  test('há explicação para as 4 categorias, curta o bastante', () {
    for (final c in ['acesso', 'autenticacao', 'vpn', 'erros']) {
      expect(explicacaoCategoria[c], isNotNull, reason: c);
      expect(explicacaoCategoria[c]!.length, lessThan(260), reason: c);
    }
  });
}

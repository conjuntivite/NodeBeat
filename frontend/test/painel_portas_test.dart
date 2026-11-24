import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/widgets/painel_portas.dart';

PortaVista _p(String n, [String e = 'up', bool uplink = false]) => PortaVista(nome: n, estado: e, uplink: uplink);

Widget _app(Widget w, [Brightness b = Brightness.light]) =>
    MaterialApp(theme: tradeTheme(b), home: Scaffold(body: SingleChildScrollView(child: w)));

void main() {
  testWidgets('ordena ímpar em cima e par embaixo', (tester) async {
    await tester.pumpWidget(_app(PainelPortas(portas: [_p('0/4'), _p('0/2'), _p('0/3'), _p('0/1')])));
    Offset at(String n) => tester.getTopLeft(find.byKey(Key('porta-$n')));
    expect(at('0/1').dy, at('0/3').dy);
    expect(at('0/2').dy, at('0/4').dy);
    expect(at('0/1').dy, lessThan(at('0/2').dy));
    expect(at('0/1').dx, lessThan(at('0/3').dx));
  });

  testWidgets('5 portas: fileira de baixo alinhada à esquerda com a de cima', (tester) async {
    await tester.pumpWidget(_app(PainelPortas(portas: [for (var i = 1; i <= 5; i++) _p('0/$i')])));
    Offset at(String n) => tester.getTopLeft(find.byKey(Key('porta-$n')));
    expect(at('0/2').dx, at('0/1').dx);
  });

  testWidgets('paridade pelo número do nome: ether2..ether5', (tester) async {
    await tester.pumpWidget(_app(PainelPortas(portas: [for (var i = 2; i <= 5; i++) _p('ether$i')])));
    Offset at(String n) => tester.getTopLeft(find.byKey(Key('porta-$n')));
    expect(at('ether3').dy, at('ether5').dy);
    expect(at('ether2').dy, at('ether4').dy);
    expect(at('ether3').dy, lessThan(at('ether2').dy));
  });

  testWidgets('SFP vai para o grupo da direita', (tester) async {
    await tester.pumpWidget(_app(PainelPortas(portas: [_p('sfp1'), _p('ether1'), _p('ether2')])));
    expect(tester.getTopLeft(find.byKey(const Key('porta-sfp1'))).dx,
        greaterThan(tester.getTopLeft(find.byKey(const Key('porta-ether2'))).dx));
  });

  testWidgets('cores por estado nos dois temas', (tester) async {
    for (final b in [Brightness.light, Brightness.dark]) {
      final t = b == Brightness.light ? TradeTokens.light : TradeTokens.dark;
      await tester.pumpWidget(_app(PainelPortas(portas: [_p('1', 'caiu'), _p('2', 'up'), _p('3', 'down')]), b));
      await tester.pumpAndSettle();
      Color? cor(String n) => ((tester.widget<Container>(find.byKey(Key('porta-$n'))).decoration) as BoxDecoration).color;
      expect(cor('1'), t.negativeFill);
      expect(cor('2'), t.positiveFill);
      expect(cor('3'), t.borderStrong); // sem link: neutro forte, visível sobre bgSurface
    }
  });

  test('estadoPorta respeita 24 h', () {
    final agora = DateTime.utc(2026, 1, 2, 12);
    expect(estadoPorta({'up': true}, agora), 'up');
    expect(estadoPorta({'up': false, 'caiu_em': '2026-01-02T00:00:00+00:00'}, agora), 'caiu');
    expect(estadoPorta({'up': false, 'caiu_em': '2026-01-01T11:00:00+00:00'}, agora), 'down');
    expect(estadoPorta({'up': false}, agora), 'down');
  });

  testWidgets('toque chama aoTocar', (tester) async {
    PortaVista? tocada;
    await tester.pumpWidget(_app(PainelPortas(portas: [_p('0/1')], aoTocar: (p) => tocada = p)));
    await tester.tap(find.byKey(const Key('porta-0/1')));
    expect(tocada?.nome, '0/1');
  });
}

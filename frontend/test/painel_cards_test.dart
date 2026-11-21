import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/painel_cards.dart';

PontoSerie _p(int h, int n) => PontoSerie(DateTime.utc(2026, 3, 5, h), {'acesso': n, 'autenticacao': n, 'vpn': n, 'erros': n});

Future<void> _mostra(WidgetTester t, Widget w, {Brightness b = Brightness.light, double largura = 400}) async {
  t.view.physicalSize = Size(largura, 1200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: tradeTheme(b), home: Scaffold(body: SingleChildScrollView(child: w))));
  await t.pump();
}

EstadoCategoria _est(String estado, int? delta) => EstadoCategoria.fromJson({'estado': estado, 'delta_pct': delta});

void main() {
  for (final b in Brightness.values) {
    testWidgets('card de acesso: sobretítulo, selo, número, variação e explicação (${b.name})', (t) async {
      var aberto = false;
      await _mostra(
          t,
          CartaoCategoria(
              categoria: 'acesso',
              total: 23445,
              estado: _est('esperado', 4),
              serie: [_p(1, 2), _p(2, 5), _p(3, 3)],
              aoVerDetalhes: () => aberto = true),
          b: b);
      expect(find.text('ACESSO'), findsOneWidget);
      expect(find.text('Esperado'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('total-acesso'))).data, '23.445');
      expect(find.text('↗ +4% vs. média 7 dias'), findsOneWidget);
      expect(find.textContaining('Tentativas de entrar nas MKs'), findsOneWidget);
      await t.tap(find.text('Ver detalhes →'));
      expect(aberto, true);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('erros em atenção com alta usa o selo Atenção', (t) async {
    await _mostra(t, CartaoCategoria(categoria: 'erros', total: 194, estado: _est('atencao', 38), serie: [_p(1, 1)], aoVerDetalhes: () {}));
    expect(find.text('Atenção'), findsOneWidget);
    expect(find.text('↗ +38% vs. média 7 dias'), findsOneWidget);
  });

  testWidgets('sem estado e série vazia não quebra: sem selo e "—"', (t) async {
    await _mostra(t, CartaoCategoria(categoria: 'vpn', total: 0, estado: null, serie: const [], aoVerDetalhes: () {}));
    expect(find.text('Normal'), findsNothing);
    expect(find.text('—'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('largura de 360 px sem overflow', (t) async {
    await _mostra(t, CartaoCategoria(categoria: 'autenticacao', total: 7390, estado: _est('normal', -2), serie: [_p(1, 1), _p(2, 2)], aoVerDetalhes: () {}),
        largura: 360);
    expect(t.takeException(), isNull);
  });
}

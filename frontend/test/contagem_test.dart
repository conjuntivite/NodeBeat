import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/contagem.dart';

Widget _app(Widget w) => MaterialApp(theme: tradeTheme(Brightness.light), home: Scaffold(body: Center(child: w)));

void main() {
  testWidgets('conta os segundos até a próxima atualização', (t) async {
    await t.pumpWidget(_app(ContagemAtualizacao(intervalo: const Duration(seconds: 15), ciclo: 0, aoAtualizar: () {})));
    expect(find.text('Atualiza em 15 s'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    expect(find.text('Atualiza em 10 s'), findsOneWidget);
    await t.pump(const Duration(seconds: 20));
    expect(find.text('Atualiza em 0 s'), findsOneWidget); // nunca negativo
  });

  testWidgets('novo ciclo recomeça a contagem', (t) async {
    Widget w(int c) => _app(ContagemAtualizacao(intervalo: const Duration(seconds: 15), ciclo: c, aoAtualizar: () {}));
    await t.pumpWidget(w(0));
    await t.pump(const Duration(seconds: 7));
    expect(find.text('Atualiza em 8 s'), findsOneWidget);
    await t.pumpWidget(w(1));
    expect(find.text('Atualiza em 15 s'), findsOneWidget);
  });

  testWidgets('toque atualiza agora', (t) async {
    var n = 0;
    await t.pumpWidget(_app(ContagemAtualizacao(intervalo: const Duration(seconds: 15), ciclo: 0, aoAtualizar: () => n++)));
    await t.tap(find.byType(ContagemAtualizacao));
    expect(n, 1);
  });
}

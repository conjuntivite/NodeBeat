import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/graficos.dart';

Future<void> _mostra(WidgetTester t, Widget w, Brightness b) async {
  t.view.physicalSize = const Size(900, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: tradeTheme(b), home: Scaffold(body: Center(child: SizedBox(width: 600, child: w)))));
  await t.pump(const Duration(milliseconds: 600));
}

final _pontos = [
  PontoSerie(DateTime.utc(2026, 3, 5, 14), {'acesso': 2, 'erros': 1}),
  PontoSerie(DateTime.utc(2026, 3, 5, 15), {'acesso': 1, 'vpn': 3}),
];

String _hh(DateTime d) => d.toLocal().hour.toString().padLeft(2, '0');

void main() {
  test('picoDe: hora e total do maior ponto; null sem dados', () {
    // _pontos: 14h soma 3, 15h soma 4
    expect(GraficoLinha.picoDe(_pontos, const ['acesso', 'erros', 'vpn']), '${_hh(_pontos[1].hora)}h · 4');
    expect(GraficoLinha.picoDe(_pontos, const ['acesso']), '${_hh(_pontos[0].hora)}h · 2');
    expect(GraficoLinha.picoDe(const [], const ['acesso']), isNull);
    expect(GraficoLinha.picoDe([PontoSerie(DateTime.utc(2026, 3, 5, 14), {'acesso': 0})], const ['acesso']), isNull);
  });

  for (final b in Brightness.values) {
    testWidgets('barras mostram rótulo e número (${b.name})', (t) async {
      await _mostra(t, const GraficoBarras(dados: [('Alfa', 9), ('Beta', 3)]), b);
      expect(find.text('Alfa'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('linha mostra legenda por série e o pico (${b.name})', (t) async {
      await _mostra(t, GraficoLinha(pontos: _pontos, series: const ['acesso', 'vpn']), b);
      expect(find.text('Acesso'), findsOneWidget);
      expect(find.text('VPN'), findsOneWidget);
      expect(find.text('Pico: ${GraficoLinha.picoDe(_pontos, const ['acesso', 'vpn'])}'), findsOneWidget);
    });
  }

  testWidgets('sem dados, barras e linha mostram o aviso', (t) async {
    await _mostra(t, const GraficoBarras(dados: []), Brightness.light);
    expect(find.text('Sem eventos no período'), findsOneWidget);
    await _mostra(t, const GraficoLinha(pontos: [], series: ['acesso']), Brightness.dark);
    expect(find.text('Sem eventos no período'), findsOneWidget);
  });
}

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
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

  for (final b in Brightness.values) {
    testWidgets('barras: trilho visível (borderSubtle) e número tabular (${b.name})', (t) async {
      await _mostra(t, const GraficoBarras(dados: [('Alfa', 9)]), b);
      final tk = b == Brightness.dark ? TradeTokens.dark : TradeTokens.light;
      expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).backgroundColor, tk.borderSubtle);
      expect(t.widget<Text>(find.text('9')).style!.fontFeatures, contains(const FontFeature.tabularFigures()));
    });
  }

  testWidgets('GraficoPizza mostra legenda com %', (t) async {
    await _mostra(t, const GraficoPizza(fatias: [('Alfa', 3), ('Beta', 1)], centro: '4 W'), Brightness.light);
    expect(find.textContaining('75%'), findsOneWidget);
    expect(find.textContaining('25%'), findsOneWidget);
    expect(find.textContaining('Alfa'), findsOneWidget);
    expect(find.text('4 W'), findsOneWidget);
  });

  testWidgets('GraficoPizza vazio', (t) async {
    await _mostra(t, const GraficoPizza(fatias: []), Brightness.dark);
    expect(find.text('Sem eventos no período'), findsOneWidget);
    await _mostra(t, const GraficoPizza(fatias: [('A', 0)]), Brightness.dark);
    expect(find.text('Sem eventos no período'), findsOneWidget);
  });

  testWidgets('GraficoPizza tabela', (t) async {
    await _mostra(t, const GraficoPizza(fatias: [('Alfa', 3), ('Beta', 1)]), Brightness.light);
    expect(find.byType(PieChart), findsOneWidget);
    await t.tap(find.text('Ver como tabela'));
    await t.pump();
    expect(find.byType(PieChart), findsNothing);
    expect(find.text('Alfa'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    await t.tap(find.text('Ver como gráfico'));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.byType(PieChart), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('GraficoCapacidade desenha com limite (${b.name})', (t) async {
      final pontos = [for (var i = 0; i < 5; i++) (DateTime.utc(2026, 3, 1 + i), 100.0 + i * 10)];
      await _mostra(t, GraficoCapacidade(pontos: pontos, limite: 240, tendenciaDia: 5, unidade: 'W'), b);
      expect(find.byType(LineChart), findsOneWidget);
      final d = t.widget<LineChart>(find.byType(LineChart)).data;
      expect(d.lineBarsData.length, 2); // série + projeção
      expect(d.lineBarsData.first.barWidth, 2);
      expect(d.extraLinesData.horizontalLines.single.y, 240);
    });
  }

  testWidgets('GraficoCapacidade vazio', (t) async {
    await _mostra(t, const GraficoCapacidade(pontos: [], unidade: 'W'), Brightness.light);
    expect(find.text('Sem eventos no período'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
  });
}

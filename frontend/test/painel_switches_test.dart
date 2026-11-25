import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/painel_switches.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/shell.dart' show Indicador;
import 'package:nodebeat/widgets/graficos.dart';

Map<String, dynamic> _cap(String nome, {bool poe = true, int dias = 10}) => {
      'switch_nome': nome,
      'atual': {
        'poe_usado_w': poe ? 120.0 : null,
        'poe_max_w': poe ? 250.0 : null,
        'clientes': 18,
        'temperatura': 41.0,
        'portas_total': 24,
        'portas_em_uso': 18,
        'poe_por_porta': poe
            ? [
                for (var i = 1; i <= 7; i++) {'porta': i, 'w': 10.0 * i},
              ]
            : <Object>[],
      },
      'historico': [
        for (var i = 0; i < 3; i++)
          {
            'em': DateTime.utc(2026, 11, 20 + i).toIso8601String(),
            'poe_usado_w': poe ? 100.0 + i : null,
            'clientes': 15 + i,
            'temperatura': 40.0 + i,
          },
      ],
      'projecoes': {
        'dias_historico': dias,
        if (poe) 'poe': {'dias_ate_80': 12, 'tendencia_w_dia': 1.5} else 'poe': null,
        'temperatura': {'tendencia_c_semana': 0.7},
        'portas': {'dias_ate_cheio': null},
      },
    };

EventosSwitches _dados({int? projecao = 30, bool poe = true, int dias = 10, int anterior = 10, int instaveis = 1}) => EventosSwitches.fromJson({
      'contagens': {'clientes': 7, 'alertas': 3, 'poe': 2, 'mudancas': 1},
      'eventos': [
        {
          'quando': DateTime.now().toUtc().toIso8601String(),
          'switch_nome': 'SW Sede',
          'porta': 5,
          'mensagem': 'PoE religado na porta',
          'severidade': 'high',
        },
      ],
      'totais': {
        'eventos': 14,
        'eventos_anterior': anterior,
        'quedas_cliente': 22,
        'quedas_cliente_anterior': 25,
        'portas_instaveis': instaveis,
        'projecao_30d': projecao,
      },
      'serie': [
        for (var i = 0; i < 4; i++)
          {'hora': DateTime.utc(2026, 11, 24, i).toIso8601String(), 'clientes': i, 'alertas': 1, 'poe': 0, 'mudancas': 0},
      ],
      'portas_top': [
        {'switch_nome': 'SW Sede', 'porta': 5, 'eventos': 9, 'projecao_mes': 270.0, 'instavel': true},
        {'switch_nome': 'SW Sede', 'porta': 7, 'eventos': 2, 'projecao_mes': 60.0, 'instavel': false},
      ],
      'clientes_top': [
        {'cliente': 'Cliente A', 'switch_nome': 'SW Sede', 'quedas': 4},
      ],
      'capacidade': [_cap('SW Sede', poe: poe, dias: dias)],
    });

Future<void> _show(WidgetTester t, EventosSwitches d, {Brightness b = Brightness.light, double w = 1100}) async {
  t.view.physicalSize = Size(w, 6000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(b),
    home: Scaffold(body: SingleChildScrollView(child: PainelSwitches(dados: d))),
  ));
  await t.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('indicadores mostram totais e variação', (t) async {
    await _show(t, _dados());
    for (final r in ['Eventos', 'Quedas de cliente', 'Portas instáveis', 'Projeção 30 dias']) {
      expect(find.text(r), findsOneWidget, reason: r);
    }
    expect(find.text('+40% ↗'), findsOneWidget);
    expect(find.text('−12% ↘'), findsOneWidget);
    expect(find.text('14'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
  });

  test('textoVariacao sem base não mostra %', () {
    expect(textoVariacao(5, 0), isNull);
    expect(textoVariacao(5, null), isNull);
    expect(textoVariacao(10, 10), '0% →');
  });

  testWidgets('período anterior 0 não mostra % nos eventos', (t) async {
    await _show(t, _dados(anterior: 0));
    expect(find.text('+40% ↗'), findsNothing);
    expect(find.textContaining('↗'), findsNothing);
    expect(find.text('−12% ↘'), findsOneWidget); // quedas seguem com base
  });

  testWidgets('valor de Portas instáveis em warning só quando > 0', (t) async {
    Color? cor() => t.widget<Text>(find.descendant(of: find.ancestor(of: find.text('Portas instáveis'), matching: find.byType(Indicador)), matching: find.byType(Text)).at(1)).style?.color;
    await _show(t, _dados());
    final tk = tokensOf(t.element(find.byType(PainelSwitches)));
    expect(cor(), tk.warning);
    await _show(t, _dados(instaveis: 0));
    expect(cor(), isNot(tk.warning));
  });

  testWidgets('1h mostra — na projeção', (t) async {
    await _show(t, _dados(projecao: null));
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('porta instável tem Selo e linha ~N/mês', (t) async {
    await _show(t, _dados());
    expect(find.text('Instável'), findsOneWidget);
    expect(find.text('SW Sede · Porta 5'), findsWidgets);
    expect(find.text('~270/mês'), findsOneWidget);
    expect(find.text('~60/mês'), findsOneWidget);
    expect(find.byType(GraficoBarras), findsNWidgets(2));
  });

  testWidgets('cards de gráficos e capacidade aparecem', (t) async {
    await _show(t, _dados());
    for (final r in ['Eventos ao longo do tempo', 'Eventos por grupo', 'Portas que mais oscilam', 'Clientes que mais caem', 'Capacidade — SW Sede']) {
      expect(find.text(r), findsOneWidget, reason: r);
    }
    expect(find.byType(GraficoLinha), findsOneWidget);
    expect(find.byType(GraficoCapacidade), findsNWidgets(3));
    expect(find.byType(GraficoPizza), findsNWidgets(3)); // grupos + portas + PoE
    expect(find.text('PoE chega a 80% em ~12 dias'), findsOneWidget);
    expect(find.text('Temperatura +0,7 °C/semana'), findsOneWidget);
    expect(find.text('Portas estáveis'), findsOneWidget);
  });

  testWidgets('switch sem PoE não tem pizza de PoE', (t) async {
    await _show(t, _dados(poe: false));
    expect(find.byType(GraficoCapacidade), findsNWidgets(2));
    expect(find.byType(GraficoPizza), findsNWidgets(2)); // grupos + portas
    expect(find.textContaining('PoE chega'), findsNothing);
    expect(find.text('PoE estável'), findsNothing);
  });

  testWidgets('menos de 7 dias mostra coletando histórico', (t) async {
    await _show(t, _dados(dias: 3));
    expect(find.text('Coletando histórico (3 dias de 7)'), findsOneWidget);
    expect(find.textContaining('PoE chega'), findsNothing);
    expect(find.text('Portas estáveis'), findsNothing);
  });

  testWidgets('Últimos eventos fica recolhido e expande', (t) async {
    await _show(t, _dados());
    expect(find.text('Últimos eventos'), findsOneWidget);
    expect(find.text('PoE religado na porta'), findsNothing);
    await t.tap(find.text('Últimos eventos'));
    await t.pumpAndSettle();
    expect(find.text('PoE religado na porta'), findsOneWidget);
    expect(find.text('Alta'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('360 px sem estouro (${b.name})', (t) async {
      await _show(t, _dados(), b: b, w: 360);
      expect(find.text('Capacidade — SW Sede'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}

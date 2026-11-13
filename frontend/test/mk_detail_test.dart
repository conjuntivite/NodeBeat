import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/mk_detail.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/widgets/common.dart';
import 'package:nodebeat/widgets/heartbeat.dart';

http.Response _json(Object o) =>
    http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _show(WidgetTester t,
    {required List<String> alertas,
    String ipPublico = '203.0.113.9',
    int statusCode = 200,
    List<Map<String, dynamic>> hist = const []}) async {
  t.view.physicalSize = const Size(1000, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final mock = MockClient((req) async {
    switch (req.url.path) {
      case '/api/mks/x':
        return _json({
          'id': 'x', 'nome': 'cliente-v7', 'ip_tunel': '10.0.0.2', 'ip_publico': ipPublico, 'usuario': 'monitor',
          'interfaces_vigiadas': ['ether1'], 'cert_sha256': null,
          'estado': {'status': 'no_ar', 'detalhe': null, 'desde': '2026-01-01T10:00:00-03:00', 'cpu': 92, 'mem': 40,
            'uptime': '1d', 'ifaces': {'ether1': false}, 'versao': '7.14', 'atualizado_em': null},
        });
      case '/api/mks/x/historico':
        return _json(hist);
      default: // /api/status
        if (statusCode != 200) return http.Response('', statusCode);
        return _json({
          'resumo': {'no_ar': 0, 'com_alerta': 1, 'fora': 0}, 'fila_pendente': 0, 'sede_ok': true, 'dados_ok': true,
          'mks': [
            {'id': 'x', 'nome': 'cliente-v7', 'status': 'no_ar', 'desde': null, 'cpu': 92, 'mem': 40, 'uptime': '1d',
              'ifaces_ok': 0, 'ifaces_total': 1, 'alertas': alertas, 'versao': '7.14'},
          ],
        });
    }
  });
  final api = ApiClient(client: mock);
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(Brightness.light),
    home: MkDetailScreen(api: api, id: 'x'),
    onGenerateRoute: (s) => MaterialPageRoute(settings: s, builder: (_) => Text('ROTA ${s.name}')),
  ));
  await t.pump();
  await t.pump();
}

HeartbeatPainter _painter(WidgetTester t) =>
    t.widget<CustomPaint>(find.descendant(of: find.byType(HeartbeatLine), matching: find.byType(CustomPaint))).painter
        as HeartbeatPainter;

void main() {
  testWidgets('MK com alerta: pílula "Alerta", batimento em warning e textos dos alertas', (t) async {
    await _show(t, alertas: ['CPU alta (92%)', 'Interface ether1 caída']);
    expect(find.textContaining('Alerta'), findsOneWidget);
    expect(find.text('CPU alta (92%) · Interface ether1 caída'), findsOneWidget);
    expect(_painter(t).color, TradeTokens.light.warning);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('sem alertas: No ar em positive; valor vazio vira "—"', (t) async {
    await _show(t, alertas: [], ipPublico: '');
    expect(find.textContaining('No ar'), findsOneWidget);
    expect(_painter(t).color, TradeTokens.light.positive);
    final ip = find.ancestor(of: find.text('IP público'), matching: find.byType(Column)).first;
    expect(find.descendant(of: ip, matching: find.text('—')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('histórico em pt-BR; retorno mostra a data do fim', (t) async {
    const ini = '2026-01-01T10:00:00-03:00', fim = '2026-01-01T10:30:00-03:00';
    await _show(t, alertas: [], hist: [
      {'evento': 'retorno', 'tipo': 'vpn_caiu', 'mk': null, 'detalhe': 'vpn', 'inicio': ini, 'fim': fim, 'duracao_s': 1800},
      {'evento': 'queda', 'tipo': 'cpu_alta', 'mk': null, 'detalhe': '', 'inicio': ini, 'fim': null, 'duracao_s': null},
    ]);
    expect(find.text('VPN caiu · Retorno · vpn · ${formatDateTime(fim)} · 30 min'), findsOneWidget);
    expect(find.text('CPU alta · Queda · ${formatDateTime(ini)}'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('status() com 500: detalhe aparece, sem alertas', (t) async {
    await _show(t, alertas: ['CPU alta (92%)'], statusCode: 500);
    expect(find.textContaining('No ar'), findsOneWidget);
    expect(find.text('Editar'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('deep link: seta de voltar leva ao painel', (t) async {
    await _show(t, alertas: []);
    await t.tap(find.byTooltip('Voltar'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('ROTA /painel'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('uma ação de marca: só "Editar" é FilledButton (fora o destrutivo)', (t) async {
    await _show(t, alertas: []);
    final filled = t.widgetList<FilledButton>(find.byType(FilledButton))
        .where((b) => (b.child as Text).data != 'Remover')
        .map((b) => (b.child as Text).data);
    expect(filled, ['Editar']);
    expect(find.widgetWithText(OutlinedButton, 'Escolher interfaces'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Aceitar novo certificado'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}

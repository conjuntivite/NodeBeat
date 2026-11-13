import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/mk_detail.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/widgets/heartbeat.dart';

http.Response _json(Object o) =>
    http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _show(WidgetTester t, {required List<String> alertas, String ipPublico = '203.0.113.9'}) async {
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
        return _json([]);
      default: // /api/status
        return _json({
          'resumo': {'no_ar': 0, 'com_alerta': 1, 'fora': 0}, 'fila_pendente': 0, 'sede_ok': true,
          'mks': [
            {'id': 'x', 'nome': 'cliente-v7', 'status': 'no_ar', 'desde': null, 'cpu': 92, 'mem': 40, 'uptime': '1d',
              'ifaces_ok': 0, 'ifaces_total': 1, 'alertas': alertas, 'versao': '7.14'},
          ],
        });
    }
  });
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(Brightness.light),
    home: MkDetailScreen(api: ApiClient(client: mock), id: 'x'),
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
}

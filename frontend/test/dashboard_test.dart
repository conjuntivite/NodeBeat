import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/dashboard.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/common.dart';

Map<String, dynamic> _mk(String id, String nome, String status, [List<String> alertas = const []]) => {
      'id': id, 'nome': nome, 'status': status, 'desde': '2026-01-01T10:00:00-03:00', 'cpu': 12.0, 'mem': 40,
      'uptime': '1d2h', 'ifaces_ok': 2, 'ifaces_total': 3, 'alertas': alertas, 'versao': '7.14',
    };

Future<void> _show(WidgetTester t, Map<String, dynamic> body, {int status = 200}) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = ApiClient(client: MockClient((req) async => http.Response(jsonEncode(body), status)));
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(Brightness.light),
    onGenerateRoute: (s) => MaterialPageRoute(
        settings: s, builder: (_) => s.name == '/login' ? const Text('LOGIN') : DashboardScreen(api: api)),
  ));
  await t.pump();
  await t.pump();
}

Map<String, dynamic> _status({int fila = 0, bool sede = true}) => {
      'resumo': {'no_ar': 1, 'com_alerta': 1, 'fora': 1},
      'fila_pendente': fila,
      'sede_ok': sede,
      'mks': [
        _mk('a', 'cliente-v7', 'vpn_caiu'),
        _mk('b', 'cliente-b', 'no_ar', ['CPU alta (92%)']),
        _mk('c', 'cliente-c', 'no_ar'),
      ],
    };

Finder _rows() => find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('row-'));

void main() {
  testWidgets('cards 1/1/1, primeira linha é a que está fora, banner da fila', (t) async {
    await _show(t, _status(fila: 3));
    for (final k in ['resumo-no_ar', 'resumo-alerta', 'resumo-fora']) {
      expect(find.descendant(of: find.byKey(Key(k)), matching: find.text('1')), findsOneWidget, reason: k);
    }
    expect(find.descendant(of: _rows().first, matching: find.text('cliente-v7')), findsOneWidget);
    expect(find.text('3 eventos aguardando envio'), findsOneWidget);
    expect(find.text('Sem conexão da sede — dados congelados'), findsNothing);
    expect(find.text('2/3'), findsNWidgets(3));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('sem sede → aviso; sem fila → sem banner de fila', (t) async {
    await _show(t, _status(sede: false));
    expect(find.text('Sem conexão da sede — dados congelados'), findsOneWidget);
    expect(find.textContaining('aguardando envio'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('clicar no cabeçalho ordena por condomínio', (t) async {
    await _show(t, _status());
    await t.tap(find.text('Condomínio'));
    await t.pump();
    expect(find.descendant(of: _rows().first, matching: find.text('cliente-b')), findsOneWidget);
    await t.tap(find.text('Condomínio'));
    await t.pump();
    expect(find.descendant(of: _rows().first, matching: find.text('cliente-v7')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('401 volta ao login', (t) async {
    await _show(t, {'detail': 'x'}, status: 401);
    expect(find.text('LOGIN'), findsOneWidget);
  });

  test('relativo', () {
    final now = DateTime.utc(2026, 1, 2, 12);
    expect(relativo('2026-01-02T11:59:40Z', now: now), '<1 min');
    expect(relativo('2026-01-02T11:54:00Z', now: now), '6 min');
    expect(relativo('2026-01-02T09:00:00Z', now: now), '3 h');
    expect(relativo('2025-12-30T12:00:00Z', now: now), '3 d');
  });
}

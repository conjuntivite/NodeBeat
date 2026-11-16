import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/faixas.dart';
import 'package:nodebeat/theme/theme.dart';

http.Response _json(Object o, [int code = 200]) =>
    http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _mk(String id, String nome, String rede, {bool desat = false, bool tunel = false}) => {
      'id': id, 'nome': nome, 'lido_em': '2026-01-01T10:00:00+00:00', 'erro': null, 'desatualizado': desat,
      'redes': [{'rede': rede, 'origem': 'ether2', 'interface': 'ether2', 'tunel': tunel}],
    };

Future<void> _show(WidgetTester t, {bool desat = false, Brightness b = Brightness.light, bool sobrepoe = false}) async {
  t.view.physicalSize = const Size(1000, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = ApiClient(
    client: MockClient((req) async => switch (req.url.path) {
          '/api/faixas' => _json({
              'mks': [_mk('a', 'condo-alfa', '10.30.0.0/24', desat: desat), _mk('b', 'condo-beta', '10.31.0.0/24', tunel: true)],
              'sede': ['192.168.0.0/24'],
              'sobreposicoes': sobrepoe
                  ? [{'a': 'condo-alfa', 'rede_a': '10.30.0.0/24', 'b': 'condo-beta', 'rede_b': '10.30.0.0/25'}]
                  : [],
            }),
          '/api/faixas/conferir' => _json({
              'faixa': '10.30.0.0/24', 'resultado': 'em_uso',
              'colisoes': [{'nome': 'condo-alfa', 'rede': '10.30.0.0/24'}], 'avisos': [], 'faltam': [],
            }),
          _ => http.Response('', 404),
        }),
  );
  await t.pumpWidget(MaterialApp(theme: tradeTheme(b), home: FaixasScreen(api: api)));
  await t.pump();
  await t.pump();
}

void main() {
  testWidgets('lista as MKs e a sede', (t) async {
    await _show(t);
    expect(find.text('condo-alfa'), findsOneWidget);
    expect(find.text('condo-beta'), findsOneWidget);
    expect(find.text('10.30.0.0/24'), findsOneWidget);
    expect(find.text('túnel'), findsOneWidget);
    expect(find.text('Sede'), findsOneWidget);
    expect(find.text('192.168.0.0/24'), findsOneWidget);
  });

  testWidgets('mostra o alerta de sobreposição', (t) async {
    await _show(t, sobrepoe: true);
    expect(find.textContaining('condo-alfa (10.30.0.0/24) sobrepõe condo-beta (10.30.0.0/25)'), findsOneWidget);
  });

  testWidgets('conferir faixa mostra "Em uso" e o condomínio', (t) async {
    await _show(t);
    await t.enterText(find.byType(TextField), '10.30.0.0/24');
    await t.tap(find.text('Conferir'));
    await t.pump();
    await t.pump();
    expect(find.text('Em uso'), findsOneWidget);
    expect(find.text('condo-alfa (10.30.0.0/24)'), findsOneWidget);
  });

  testWidgets('MK desatualizada mostra o aviso', (t) async {
    await _show(t, desat: true);
    expect(find.text('dados desatualizados'), findsOneWidget);
  });

  testWidgets('renderiza nos temas claro e escuro sem exceção', (t) async {
    for (final b in Brightness.values) {
      await _show(t, b: b, desat: true, sobrepoe: true);
      expect(t.takeException(), isNull);
      expect(find.text('condo-alfa'), findsOneWidget);
    }
  });
}

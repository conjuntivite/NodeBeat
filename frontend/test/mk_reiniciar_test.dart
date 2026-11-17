import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/audio/monitor_sound.dart';
import 'package:nodebeat/screens/mk_detail.dart';
import 'package:nodebeat/theme/theme.dart';

http.Response _json(Object o, [int code = 200]) =>
    http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json; charset=utf-8'});

const _estado = {'status': 'reiniciando', 'detalhe': 'Túnel e IP público sem resposta', 'desde': '2026-01-01T10:00:00-03:00',
  'ifaces': {}};
const _mk = {'id': 'x', 'nome': 'MK Norte', 'ip_tunel': '10.8.0.2', 'ip_publico': '8.8.4.4', 'usuario': 'monitor',
  'interfaces_vigiadas': [], 'cert_sha256': null, 'estado': _estado};
const _reinicio = {'evento': 'reinicio', 'tipo': 'reinicio', 'mk': {'id': 'x', 'nome': 'MK Norte'},
  'detalhe': 'Solicitado por ana', 'inicio': '2026-01-01T10:00:00-03:00', 'fim': null, 'duracao_s': null};
const _inv = {'lido_em': null, 'erro': null, 'desatualizado': false, 'redes': [], 'pools': [], 'nat': [], 'servicos': []};

Future<List<http.Request>> _show(WidgetTester t, {Brightness b = Brightness.light}) async {
  t.view.physicalSize = const Size(1200, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final posts = <http.Request>[];
  final api = ApiClient(client: MockClient((req) async {
    if (req.method == 'POST') {
      posts.add(req);
      return http.Response('', 204);
    }
    return switch (req.url.path) {
      '/api/mks/x' => _json(_mk),
      '/api/mks/x/historico' => _json([_reinicio]),
      '/api/mks/x/inventario' => _json(_inv),
      '/api/mks/x/ips' => _json([]),
      _ => _json({'resumo': {'no_ar': 0, 'com_alerta': 0, 'fora': 0}, 'fila_pendente': 0, 'sede_ok': true,
          'dados_ok': true, 'mks': []}),
    };
  }));
  await t.pumpWidget(MaterialApp(theme: tradeTheme(b), home: MkDetailScreen(api: api, id: 'x')));
  await t.pumpAndSettle();
  return posts;
}

void main() {
  testWidgets('reiniciando: pílula própria e histórico mostra quem pediu', (t) async {
    await _show(t);
    expect(find.textContaining('Reiniciando ·'), findsOneWidget);
    expect(find.textContaining('Reinício · Solicitado por ana'), findsOneWidget);
  });

  testWidgets('reiniciar só libera depois de digitar o nome da MK e chama a API (tema escuro)', (t) async {
    final posts = await _show(t, b: Brightness.dark);
    await t.tap(find.widgetWithText(OutlinedButton, 'Reiniciar'));
    await t.pumpAndSettle();
    final ok = find.widgetWithText(FilledButton, 'Reiniciar agora');
    expect(t.widget<FilledButton>(ok).onPressed, isNull);
    await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'MK Norte');
    await t.pump();
    await t.tap(ok);
    await t.pumpAndSettle();
    expect(posts.single.url.path, '/api/mks/x/reiniciar');
  });

  test('reiniciando não apita', () {
    final s = StatusData.fromJson({'resumo': {'no_ar': 0, 'com_alerta': 0, 'fora': 0}, 'fila_pendente': 0,
      'sede_ok': true, 'dados_ok': true, 'mks': [{'id': 'x', 'nome': 'n', 'status': 'reiniciando',
        'desde': '2020-01-01T00:00:00Z', 'ifaces_ok': 0, 'ifaces_total': 0, 'alertas': []}]});
    expect(soundFor(s), MonitorSound.silent);
  });
}

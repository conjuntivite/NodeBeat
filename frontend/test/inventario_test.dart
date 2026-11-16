import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/inventario.dart';

http.Response _json(Object o, [int code = 200]) =>
    http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json; charset=utf-8'});

const _inv = {
  'lido_em': '2026-01-01T10:00:00+00:00', 'erro': null, 'desatualizado': false, 'redes': [], 'pools': [],
  'nat': [
    {'protocolo': 'tcp', 'dst_port': '8081', 'to_addresses': '192.168.10.20', 'to_ports': '80', 'comentario': 'camera',
      'ativo': true, 'aberto': true},
    {'protocolo': 'udp', 'dst_port': '5060', 'to_addresses': '192.168.10.21', 'to_ports': '5060', 'comentario': '',
      'ativo': false, 'aberto': false},
  ],
  'servicos': [{'nome': 'winbox', 'porta': 8291, 'ativo': true, 'aberto': false}],
};

Map<String, dynamic> _ip(String ip) => {
      'ip': ip, 'mac': 'AA:BB:CC:00:00:01', 'host_name': 'pc1', 'fixo': true, 'primeiro_visto': '2026-01-01T10:00:00+00:00',
      'ultimo_visto': '2026-01-05T10:00:00+00:00', 'em_uso': true,
    };

Future<List<http.Request>> _show(WidgetTester t, Widget Function(ApiClient) card, {Brightness b = Brightness.light}) async {
  t.view.physicalSize = const Size(1000, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final reqs = <http.Request>[];
  var ips = [_ip('192.168.10.20')];
  final api = ApiClient(
    client: MockClient((req) async {
      reqs.add(req);
      if (req.method == 'DELETE') {
        ips = [];
        return http.Response('', 204);
      }
      return switch (req.url.path) {
        '/api/mks/x/inventario' => _json(_inv),
        '/api/mks/x/portas/conferir' =>
          _json({'porta': 9000, 'protocolo': 'tcp', 'resultado': 'livre', 'usos': [], 'avisos': [], 'desatualizado': false}),
        '/api/mks/x/ips' => _json(ips),
        '/api/mks/x/ips/conferir' => _json({
            'ip': '192.168.10.20', 'resultado': 'em_uso', 'visto': _ip('192.168.10.20'), 'avisos': [], 'desatualizado': false,
          }),
        _ => http.Response('', 404),
      };
    }),
  );
  await t.pumpWidget(MaterialApp(theme: tradeTheme(b), home: Scaffold(body: SingleChildScrollView(child: card(api)))));
  await t.pump();
  await t.pump();
  return reqs;
}

void main() {
  testWidgets('PortasCard mostra o dst-nat, desativada e o selo de aberto', (t) async {
    await _show(t, (api) => PortasCard(api: api, id: 'x'));
    expect(find.text('8081 → 192.168.10.20:80'), findsOneWidget);
    expect(find.text('desativada'), findsOneWidget);
    expect(find.text('aberto para qualquer IP (sem restrição na regra)'), findsOneWidget);
    expect(find.text('winbox 8291'), findsOneWidget);
  });

  testWidgets('PortasCard: conferir porta mostra "Livre"', (t) async {
    final reqs = await _show(t, (api) => PortasCard(api: api, id: 'x'));
    await t.enterText(find.byType(TextField), '9000');
    await t.tap(find.descendant(of: find.byType(SegmentedButton<String>), matching: find.text('UDP')));
    await t.pump();
    await t.tap(find.text('Conferir'));
    await t.pump();
    await t.pump();
    expect(find.text('Livre'), findsOneWidget);
    expect(reqs.last.url.query, 'porta=9000&protocolo=udp');
  });

  testWidgets('IpsCard mostra o selo "em uso" e conferir IP', (t) async {
    await _show(t, (api) => IpsCard(api: api, id: 'x'));
    expect(find.text('192.168.10.20'), findsOneWidget);
    expect(find.text('em uso'), findsOneWidget);
    expect(find.text('visto 05/01'), findsOneWidget);
    await t.enterText(find.byType(TextField), '192.168.10.20');
    await t.tap(find.text('Conferir'));
    await t.pump();
    await t.pump();
    expect(find.text('Em uso'), findsOneWidget);
  });

  testWidgets('esquecer confirma, chama DELETE e recarrega (tema escuro)', (t) async {
    final reqs = await _show(t, (api) => IpsCard(api: api, id: 'x'), b: Brightness.dark);
    await t.tap(find.text('esquecer'));
    await t.pumpAndSettle();
    expect(find.text('Esquecer IP'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Esquecer'));
    await t.pumpAndSettle();
    expect(reqs.any((r) => r.method == 'DELETE' && r.url.path == '/api/mks/x/ips/192.168.10.20'), isTrue);
    expect(find.text('Nenhum IP visto.'), findsOneWidget);
  });
}

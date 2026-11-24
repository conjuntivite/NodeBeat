import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/audio/monitor_sound.dart';
import 'package:nodebeat/screens/dashboard.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';

class _Quiet extends SoundEngine {
  @override
  bool get savedBip => false;
  @override
  bool get savedQueda => false;
  @override
  bool get isSuspended => false;
  @override
  void stop() {}
}

Map<String, dynamic> _eq(String id, String nome, String status, String? local, String? localNome, int total, int up) => {
      'id': id, 'tipo': 'switch', 'nome': nome, 'ip': '10.0.0.1', 'local': local, 'local_nome': localNome, 'origem': 'manual',
      'estado': {'status': status, 'desde': '2026-01-01T10:00:00-03:00', 'portas': <String, dynamic>{}, 'uplinks': <String, dynamic>{}},
      'portas_total': total, 'portas_up': up,
    };

final _status = {
  'resumo': {'no_ar': 0, 'com_alerta': 1, 'fora': 1},
  'fila_pendente': 0, 'sede_ok': true, 'dados_ok': true,
  'mks': [
    {'id': 'mk1', 'nome': 'cliente-a', 'status': 'offline', 'desde': null, 'cpu': null, 'mem': null, 'uptime': null,
     'ifaces_ok': 0, 'ifaces_total': 0, 'alertas': <String>[], 'versao': null},
  ],
};

Future<List<http.Request>> _show(WidgetTester t, {int eqStatus = 200, Brightness tema = Brightness.light}) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final reqs = <http.Request>[];
  final api = ApiClient(client: MockClient((req) async {
    reqs.add(req);
    if (req.url.path.endsWith('/equipamentos')) {
      if (req.method == 'POST') return http.Response(jsonEncode({'id': 'novo'}), 200);
      if (eqStatus != 200) return http.Response(jsonEncode({'detail': 'x'}), eqStatus);
      return http.Response(jsonEncode([
        _eq('s1', 'sw-mk', 'offline', 'mk1', 'cliente-a', 8, 0),
        _eq('s2', 'sw-sede', 'no_ar', 'sede', 'Sede', 24, 10),
      ]), 200);
    }
    return http.Response(jsonEncode(_status), 200);
  }));
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(tema),
    onGenerateRoute: (s) => MaterialPageRoute(
        settings: s,
        builder: (_) => s.name == '/login'
            ? const Text('LOGIN')
            : s.name!.startsWith('/switch/') ? Text('SWITCH ${s.name}') : DashboardScreen(api: api, sound: _Quiet())),
  ));
  for (var i = 0; i < 4; i++) {
    await t.pump();
  }
  return reqs;
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
}

Future<void> _abaSwitch(WidgetTester t) async {
  await t.tap(find.byKey(const Key('nav-switch')));
  await _settle(t);
}

void main() {
  testWidgets('três abas, MK inicial, contadores', (t) async {
    await _show(t);
    // barra lateral: MK, Switch e Firewall (nome no tooltip), MK ativa
    for (final k in ['mk', 'switch', 'firewall']) {
      expect(find.byKey(Key('nav-$k')), findsOneWidget);
    }
    expect(find.text('MKs'), findsOneWidget); // título da página
    expect(find.text('No ar'), findsOneWidget); // resumo da aba MK visível
    expect(find.descendant(of: find.byKey(const Key('contador-mk')), matching: find.text('2')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('contador-switch')), matching: find.text('1')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('aba Switch agrupa por local com Sede primeiro e abre o detalhe', (t) async {
    await _show(t);
    await _abaSwitch(t);
    final sede = t.getTopLeft(find.text('Sede')).dy, mk = t.getTopLeft(find.text('cliente-a')).dy;
    expect(sede, lessThan(mk));
    expect(find.text('24 portas · 10 com link'), findsOneWidget);
    await t.tap(find.text('sw-mk'));
    await _settle(t);
    expect(find.text('SWITCH /switch/s1'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('adicionar switch envia local sede e omite community vazia', (t) async {
    final reqs = await _show(t);
    await _abaSwitch(t);
    await t.tap(find.text('Adicionar switch'));
    await _settle(t);
    await t.enterText(find.widgetWithText(TextField, 'Nome'), 'novo-sw');
    await t.enterText(find.widgetWithText(TextField, 'IP'), '10.1.1.1');
    await t.tap(find.text('Salvar'));
    await _settle(t);
    final post = reqs.firstWhere((r) => r.method == 'POST');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['local'], 'sede');
    expect(body['nome'], 'novo-sw');
    expect(body.containsKey('community'), isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('contador usa negative com fgInverse nos dois temas (contraste >= 4.5:1)', (t) async {
    for (final b in [Brightness.light, Brightness.dark]) {
      final tk = b == Brightness.light ? TradeTokens.light : TradeTokens.dark;
      await _show(t, tema: b);
      final c = find.byKey(const Key('contador-mk'));
      expect((t.widget<Container>(c).decoration as BoxDecoration).color, tk.negative);
      expect(t.widget<Text>(find.descendant(of: c, matching: find.byType(Text))).style?.color, tk.fgInverse);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('falha ao carregar switches mostra erro na aba Switch e não afeta a aba MK', (t) async {
    await _show(t, eqStatus: 500);
    expect(find.text('No ar'), findsOneWidget);
    await _abaSwitch(t);
    expect(find.text('Não foi possível carregar os switches.'), findsOneWidget);
    expect(find.text('Nenhum switch ainda.'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('401 ao carregar switches volta ao login', (t) async {
    await _show(t, eqStatus: 401);
    await _settle(t);
    expect(find.text('LOGIN'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('aba Firewall só mostra o aviso', (t) async {
    await _show(t);
    await t.tap(find.byKey(const Key('nav-firewall')));
    await _settle(t);
    expect(find.text('Nenhum firewall ainda. O suporte a firewall vem na próxima etapa.'), findsOneWidget);
    expect(find.text('Adicionar switch'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}

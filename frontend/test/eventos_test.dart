import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/mk_script.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/widgets/eventos.dart';
import 'package:nodebeat/widgets/inventario.dart';

http.Response _json(Object o) =>
    http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _ev(String quando, String tipo, String msg) => {
      'recebido_em': quando, 'severidade': 'info', 'topicos': ['system'], 'tipo': tipo, 'campos': {}, 'mensagem': msg,
    };

Future<List<Uri>> _show(WidgetTester t,
    {List<Map<String, dynamic>>? eventos, bool ativo = true, String? ipOrigem = '203.0.113.9', Brightness b = Brightness.light}) async {
  t.view.physicalSize = const Size(1000, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final urls = <Uri>[];
  final lista = eventos ??
      [
        _ev('2026-03-05T13:04:05+00:00', 'login_falha', 'login failure for user admin'),
        _ev('2026-03-05T12:00:00+00:00', 'config', 'config changed'),
      ];
  final api = ApiClient(
    client: MockClient((req) async {
      urls.add(req.url);
      return switch (req.url.path) {
        '/api/mks/x/eventos' => _json({'eventos': lista, 'syslog_ativo': ativo}),
        '/api/preparar-mk' => _json({'ip_origem': ipOrigem, 'ips_publicos_sede': []}),
        _ => http.Response('', 404),
      };
    }),
  );
  await t.pumpWidget(MaterialApp(
      theme: tradeTheme(b),
      home: Scaffold(body: SingleChildScrollView(child: EventosCard(api: api, id: 'x', ipTunel: '198.51.100.7')))));
  await t.pump();
  await t.pump();
  return urls;
}

Future<void> _tap(WidgetTester t, String texto) async {
  await t.tap(find.text(texto));
  await t.pump();
  await t.pump();
}

void main() {
  testWidgets('lista eventos com mensagem e hora local', (t) async {
    await _show(t);
    expect(find.text('login failure for user admin'), findsOneWidget);
    expect(find.text('config changed'), findsOneWidget);
    expect(find.text('Falha de login'), findsOneWidget);
    expect(find.text('login_falha'), findsNothing);
    final d = DateTime.parse('2026-03-05T13:04:05+00:00').toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    expect(find.text('${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}'), findsOneWidget);
  });

  testWidgets('chip filtra por tipo', (t) async {
    final urls = await _show(t);
    expect(urls.last.queryParametersAll['tipo'], isNull);
    await _tap(t, 'Falhas de login');
    expect(urls.last.queryParametersAll['tipo'], ['login_falha']);
  });

  testWidgets('período: padrão 24 h, 7 dias muda desde', (t) async {
    final urls = await _show(t);
    final h24 = DateTime.parse(urls.last.queryParameters['desde']!);
    expect(DateTime.now().toUtc().difference(h24).inHours, 24);
    await _tap(t, '7 dias');
    final d7 = DateTime.parse(urls.last.queryParameters['desde']!);
    expect(DateTime.now().toUtc().difference(d7).inDays, 7);
  });

  testWidgets('mostrar mais pede ate = recebido_em do último', (t) async {
    final lista = [for (var i = 0; i < 200; i++) _ev('2026-03-05T13:${(59 - i ~/ 60).toString().padLeft(2, '0')}:${(59 - i % 60).toString().padLeft(2, '0')}+00:00', 'login', 'm$i')];
    final urls = await _show(t, eventos: lista);
    await t.ensureVisible(find.text('Mostrar mais'));
    await _tap(t, 'Mostrar mais');
    expect(DateTime.parse(urls.last.queryParameters['ate']!), DateTime.parse(lista.last['recebido_em'] as String));
  });

  testWidgets('aviso sem syslog abre diálogo com o script e copia', (t) async {
    await _show(t, eventos: [], ativo: false);
    expect(find.text('Esta MK não está mandando eventos'), findsOneWidget);
    String? copiado;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copiado = (c.arguments as Map)['text'];
      return null;
    });
    await _tap(t, 'Ligar eventos');
    await t.pumpAndSettle();
    final script = scriptLigarEventos(ipOrigem: '203.0.113.9', ipTunel: '198.51.100.7');
    expect(find.textContaining('/system logging', findRichText: true), findsWidgets);
    await t.tap(find.text('Copiar'));
    await t.pump();
    expect(copiado, script);
  });

  testWidgets('ligar eventos sem IP de origem', (t) async {
    await _show(t, eventos: [], ativo: false, ipOrigem: null);
    await _tap(t, 'Ligar eventos');
    await t.pumpAndSettle();
    expect(find.textContaining('Configure NODEBEAT_IP_ORIGEM no servidor'), findsOneWidget);
    expect(find.text('Copiar'), findsNothing);
  });

  testWidgets('botão atualizar refaz a busca', (t) async {
    final urls = await _show(t);
    final n = urls.length;
    await t.tap(find.byTooltip('Atualizar'));
    await t.pump();
    await t.pump();
    expect(urls.length, n + 1);
  });

  Future<List<Completer<http.Response>>> lento(WidgetTester t, {int pageSize = 200}) async {
    t.view.physicalSize = const Size(1000, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final pend = <Completer<http.Response>>[];
    final api = ApiClient(
      client: MockClient((req) {
        final c = Completer<http.Response>();
        pend.add(c);
        return c.future;
      }),
    );
    await t.pumpWidget(MaterialApp(
        theme: tradeTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: EventosCard(api: api, id: 'x', ipTunel: '198.51.100.7')))));
    return pend;
  }

  http.Response resp(List<Map<String, dynamic>> l) => _json({'eventos': l, 'syslog_ativo': true});

  testWidgets('resposta antiga não sobrescreve a nova', (t) async {
    final pend = await lento(t);
    await t.pump(); // pedido 0 (sem filtro) pendente
    await t.tap(find.text('Falhas de login'));
    await t.pump(); // pedido 1
    pend[1].complete(resp([_ev('2026-03-05T13:00:00+00:00', 'login_falha', 'nova')]));
    await t.pump();
    pend[0].complete(resp([_ev('2026-03-05T12:00:00+00:00', 'login', 'antiga')]));
    await t.pump();
    await t.pump();
    expect(find.text('nova'), findsOneWidget);
    expect(find.text('antiga'), findsNothing);
  });

  testWidgets('duplo toque em Mostrar mais faz uma busca só', (t) async {
    final pend = await lento(t);
    await t.pump();
    pend[0].complete(resp([for (var i = 0; i < 200; i++) _ev('2026-03-05T13:00:00+00:00', 'login', 'm$i')]));
    await t.pump();
    await t.pump();
    await t.ensureVisible(find.text('Mostrar mais'));
    await t.tap(find.text('Mostrar mais'));
    await t.pump();
    await t.tap(find.text('Mostrar mais'), warnIfMissed: false);
    await t.pump();
    expect(pend.length, 2);
    pend[1].complete(resp([_ev('2026-03-05T12:00:00+00:00', 'login', 'extra')]));
    await t.pump();
    await t.pump();
    expect(find.text('extra'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('tema ${b.name}: login_falha usa negative', (t) async {
      await _show(t, b: b);
      final tok = b == Brightness.dark ? TradeTokens.dark : TradeTokens.light;
      final selo = t.widget<Selo>(find.byType(Selo).first);
      expect(selo.cor, tok.negative);
      expect(t.takeException(), isNull);
    });
  }
}

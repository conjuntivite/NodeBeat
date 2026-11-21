import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/painel_eventos.dart';
import 'package:nodebeat/theme/theme.dart';

import 'painel_api_test.dart' show painelJson;

http.Response _json(Object o, [int code = 200]) =>
    http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _zerado() => {
      'periodo': '24h',
      'gerado_em': '2026-03-05T15:00:00+00:00',
      'resumo': {'acesso': 0, 'autenticacao': 0, 'vpn': 0, 'erros': 0},
      'serie_hora': <Object>[],
      'blocos': {
        for (final c in ['acesso', 'autenticacao', 'vpn', 'erros']) c: {'total': 0, 'por_mk': <Object>[]},
      },
      'por_mk': [
        {'mk_id': 'a', 'nome': 'Alfa', 'semaforo': 'verde', 'motivos': <Object>[], 'contagens': <String, int>{}},
      ],
      'atencao': <Object>[],
      'incidentes': <Object>[],
      'config': <Object>[],
    };

Future<List<Uri>> _show(WidgetTester t,
    {Map<String, dynamic>? corpo, int status = 200, Brightness b = Brightness.light, double largura = 1100}) async {
  t.view.physicalSize = Size(largura, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final urls = <Uri>[];
  final api = ApiClient(
    client: MockClient((req) async {
      urls.add(req.url);
      return req.url.path == '/api/eventos/painel' ? _json(corpo ?? painelJson(), status) : http.Response('', 404);
    }),
  );
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(b),
    onGenerateRoute: (s) => MaterialPageRoute(
      settings: s,
      builder: (_) => s.name == '/mk/a' ? const Scaffold(body: Text('detalhe da MK a')) : PainelEventosScreen(api: api),
    ),
    initialRoute: '/eventos',
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 600));
  return urls;
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('mostra atenção, incidentes, blocos e mudanças (${b.name})', (t) async {
      await _show(t, b: b);
      expect(find.text('ATENÇÃO AGORA'), findsOneWidget);
      expect(find.textContaining('Login de fora: admin'), findsOneWidget);
      expect(find.text('Vermelho'), findsOneWidget);
      expect(find.text('Incidentes entre MKs'), findsOneWidget);
      expect(find.textContaining('Alfa, Beta, Gama'), findsOneWidget);
      for (final titulo in ['Acesso (hacker)', 'Autenticação', 'VPN', 'Erros importantes']) {
        expect(find.text(titulo), findsWidgets, reason: titulo);
      }
      expect(find.text('Acesso (hacker)'), findsOneWidget);
      expect(find.text('Erros importantes'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('total-acesso'))).data, '12');
      expect(t.widget<Text>(find.byKey(const Key('total-erros'))).data, '5');
      expect(find.text('203.0.113.9', skipOffstage: false), findsWidgets);
      expect(find.text('Mudanças de configuração', skipOffstage: false), findsOneWidget);
      expect(find.text('fora do horário', skipOffstage: false), findsOneWidget);
      expect(find.text('usuário novo', skipOffstage: false), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  for (final b in Brightness.values) {
    testWidgets('cabeçalho e card de situação (${b.name})', (t) async {
      await _show(t, b: b);
      expect(find.text('Eventos'), findsOneWidget);
      expect(find.textContaining('NODEBEAT'), findsOneWidget);
      expect(find.text('Sem invasão detectada, mas 1 MK em vermelho.'), findsOneWidget);
      expect(find.textContaining('SITUAÇÃO'), findsOneWidget);
      expect(find.textContaining('1 verde'), findsOneWidget);
      expect(find.textContaining('0 amarelas'), findsOneWidget);
      expect(find.textContaining('1 vermelha'), findsOneWidget);
      expect(find.text('1 MK pede uma olhada'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('tela estreita (360 px) sem overflow', (t) async {
    await _show(t, largura: 360);
    expect(find.text('Sem invasão detectada, mas 1 MK em vermelho.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('sem eventos: Tudo calmo', (t) async {
    await _show(t, corpo: _zerado());
    expect(find.text('Tudo calmo.'), findsOneWidget);
  });

  testWidgets('trocar o período refaz a requisição', (t) async {
    final urls = await _show(t);
    expect(urls.last.queryParameters['periodo'], '24h');
    await t.tap(find.text('7 dias'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(urls.last.queryParameters['periodo'], '7d');
  });

  testWidgets('filtrar por MK refaz a requisição com mk', (t) async {
    final urls = await _show(t);
    expect(urls.last.queryParameters.containsKey('mk'), false);
    await t.tap(find.byType(DropdownButton<String?>));
    await t.pumpAndSettle();
    await t.tap(find.text('Beta').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(urls.last.queryParameters['mk'], 'b');
  });

  testWidgets('tocar numa MK da faixa de atenção abre o detalhe', (t) async {
    await _show(t);
    await t.tap(find.byKey(const Key('atencao-a')));
    await t.pumpAndSettle();
    expect(find.text('detalhe da MK a'), findsOneWidget);
  });

  testWidgets('sem eventos mostra Tudo certo e o aviso dos gráficos', (t) async {
    await _show(t, corpo: _zerado());
    expect(find.text('Tudo certo'), findsOneWidget);
    expect(find.text('Sem eventos no período'), findsWidgets);
  });

  testWidgets('falha da API mostra o erro e Tentar de novo', (t) async {
    await _show(t, corpo: {'detail': 'x'}, status: 500);
    expect(find.text('Tentar de novo'), findsOneWidget);
  });
}

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
    {Map<String, dynamic>? corpo, int status = 200, Brightness b = Brightness.light, double largura = 1100, double altura = 2400}) async {
  t.view.physicalSize = Size(largura, altura);
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
    testWidgets('mostra atenção, cards, detalhes, incidentes e mudanças (${b.name})', (t) async {
      await _show(t, b: b, altura: 4200);
      expect(find.text('ATENÇÃO AGORA'), findsOneWidget);
      expect(find.textContaining('Login de fora: admin'), findsOneWidget);
      expect(find.text('Vermelho'), findsOneWidget);
      expect(find.text('Incidentes entre MKs'), findsOneWidget);
      expect(find.textContaining('Alfa, Beta, Gama'), findsOneWidget);
      for (final c in ['ACESSO', 'AUTENTICAÇÃO', 'VPN', 'ERROS']) {
        expect(find.text(c), findsWidgets, reason: c);
      }
      expect(t.widget<Text>(find.byKey(const Key('total-acesso'))).data, '12');
      expect(t.widget<Text>(find.byKey(const Key('total-erros'))).data, '5');
      expect(find.text('Esperado'), findsOneWidget);
      expect(find.text('Atenção'), findsOneWidget);
      expect(find.text('Quem está tentando entrar'), findsOneWidget);
      expect(find.text('203.0.113.9'), findsWidgets);
      expect(find.text('7 tentativas'), findsOneWidget);
      expect(find.text('1 login de fora aceito'), findsOneWidget);
      expect(find.text('Acesso (hacker)'), findsNothing);
      expect(find.text('Mudanças de configuração'), findsOneWidget);
      expect(find.text('fora do horário'), findsOneWidget);
      expect(find.text('usuário novo'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('sem login de fora aceito mostra o selo positivo', (t) async {
    final j = painelJson();
    ((j['blocos'] as Map)['acesso'] as Map)['logins_externos'] = <Object>[];
    await _show(t, corpo: j, altura: 4200);
    expect(find.text('Nenhum login de fora aceito'), findsOneWidget);
    expect(find.textContaining('login de fora aceito'), findsOneWidget);
  });

  testWidgets('nota de concentração aparece quando uma MK tem 25% ou mais', (t) async {
    await _show(t, altura: 4200);
    expect(find.textContaining('Alfa concentra'), findsOneWidget);
  });

  testWidgets('ordem: situação, cards, tempo/por MK, acesso, incidentes, mudanças', (t) async {
    await _show(t, altura: 4200);
    double y(Finder f) => t.getTopLeft(f.first).dy;
    final ordem = [
      y(find.textContaining('SITUAÇÃO')),
      y(find.byKey(const Key('total-acesso'))),
      y(find.text('Quando os eventos aconteceram')),
      y(find.text('Quem está tentando entrar')),
      y(find.text('Incidentes entre MKs')),
      y(find.text('Mudanças de configuração')),
    ];
    expect(ordem, [...ordem]..sort());
  });

  testWidgets('Ver detalhes rola até o detalhe sem erro', (t) async {
    await _show(t);
    await t.tap(find.text('Ver detalhes →').first);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  for (final b in Brightness.values) {
    testWidgets('tela completa em 360 px sem overflow (${b.name})', (t) async {
      await _show(t, b: b, largura: 360, altura: 6000);
      expect(find.text('Mudanças de configuração'), findsOneWidget);
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

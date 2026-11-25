import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/painel_eventos.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';

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

Map<String, dynamic> _switches() => {
      'contagens': {'clientes': 7, 'alertas': 3, 'poe': 2, 'mudancas': 1},
      'eventos': [
        {
          'quando': DateTime.now().toUtc().toIso8601String(),
          'switch_id': 's1',
          'switch_nome': 'Switch Teste',
          'porta': 5,
          'tipo': 'poe',
          'grupo': 'alertas',
          'mensagem': 'PoE religado na porta',
          'severidade': 'high',
        },
        {
          'quando': '2020-01-02T12:30:00Z',
          'switch_id': 's1',
          'switch_nome': 'Switch Teste',
          'porta': null,
          'tipo': 'config',
          'grupo': 'mudancas',
          'mensagem': 'Configuração alterada',
          'severidade': 'medium',
        },
      ],
    };

Future<List<Uri>> _show(WidgetTester t,
    {Map<String, dynamic>? corpo, int status = 200, Map<String, dynamic>? sw, int swStatus = 200, bool swFalhaNaSegunda = false, Brightness b = Brightness.light, double largura = 1100, double altura = 2400}) async {
  t.view.physicalSize = Size(largura, altura);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final urls = <Uri>[];
  final api = ApiClient(
    client: MockClient((req) async {
      urls.add(req.url);
      if (req.url.path == '/api/eventos/switches') {
        if (swFalhaNaSegunda && req.url.queryParameters['periodo'] != '24h') return _json({'detail': 'x'}, 500);
        return _json(sw ?? _switches(), swStatus);
      }
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
      expect(find.text('Quem está tentando entrar'), findsNothing); // detalhe só na janela
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
    await t.tap(find.text('Ver detalhes →').first);
    await t.pumpAndSettle();
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
      y(find.text('Incidentes entre MKs')),
      y(find.text('Mudanças de configuração')),
    ];
    expect(ordem, [...ordem]..sort());
  });

  testWidgets('Ver detalhes abre a janela com o detalhe e fecha no X', (t) async {
    await _show(t, altura: 4200);
    await t.tap(find.text('Ver detalhes →').first);
    await t.pumpAndSettle();
    expect(find.text('Quem está tentando entrar'), findsOneWidget);
    expect(find.text('203.0.113.9'), findsWidgets);
    expect(find.text('7 tentativas'), findsOneWidget);
    expect(find.text('1 login de fora aceito'), findsOneWidget);
    await t.tap(find.byTooltip('Fechar'));
    await t.pumpAndSettle();
    expect(find.text('Quem está tentando entrar'), findsNothing);
    for (var i = 1; i < 4; i++) {
      await t.tap(find.text('Ver detalhes →').at(i));
      await t.pumpAndSettle();
      expect(find.byTooltip('Fechar'), findsOneWidget);
      await t.tap(find.byTooltip('Fechar'));
      await t.pumpAndSettle();
    }
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

  testWidgets('só o ranking por MK usa a cor de marca nas barras', (t) async {
    await _show(t, altura: 4200);
    final marca = find.byWidgetPredicate((w) => w is LinearProgressIndicator && w.color == TradeTokens.light.bgBrand);
    expect(marca, findsNWidgets(2)); // Alfa e Beta no ranking
  });

  for (final b in Brightness.values) {
    testWidgets('nome de MK com 60 caracteres em 360 px sem overflow (${b.name})', (t) async {
      final longo = 'MK ${'X' * 56}';
      final j = painelJson();
      for (final m in j['por_mk'] as List) {
        (m as Map)['nome'] = longo;
      }
      (j['atencao'] as List).first['nome'] = longo;
      for (final c in ['acesso']) {
        for (final e in ((j['blocos'] as Map)[c] as Map)['por_mk'] as List) {
          (e as Map)['nome'] = longo;
        }
      }
      await _show(t, corpo: j, b: b, largura: 360, altura: 6000);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('filtrar uma MK não mostra a nota de concentração (seria sempre 100%)', (t) async {
    await _show(t, altura: 4200);
    expect(find.textContaining('% dos eventos'), findsOneWidget);
    await t.tap(find.byType(DropdownButton<String?>));
    await t.pumpAndSettle();
    await t.tap(find.text('Beta').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('% dos eventos'), findsNothing);
  });

  testWidgets('a nota usa o total de todas as MKs, não só as 10 do ranking', (t) async {
    final j = painelJson();
    j['por_mk'] = [
      for (var i = 0; i < 12; i++)
        {'mk_id': 'm$i', 'nome': 'MK$i', 'semaforo': 'verde', 'motivos': <String>[], 'contagens': {'acesso': i == 0 ? 30 : 10}},
    ];
    // MK0 = 30 de 140 (21%) do total, mas 30 de 120 (25%) só entre as 10 primeiras
    await _show(t, corpo: j, altura: 4200);
    expect(find.textContaining('% dos eventos'), findsNothing);
  });

  Future<void> abaSwitches(WidgetTester t) async {
    await t.tap(find.text('Switches'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
  }

  Future<void> abreUltimos(WidgetTester t) async {
    await t.tap(find.text('Últimos eventos'));
    await t.pumpAndSettle();
  }

  for (final b in Brightness.values) {
    testWidgets('aba Switches com indicadores e últimos eventos (${b.name})', (t) async {
      final urls = await _show(t, b: b, altura: 6000);
      expect(urls.any((u) => u.path == '/api/eventos/switches' && u.queryParameters['periodo'] == '24h'), true);
      await abaSwitches(t);
      for (final r in ['Eventos', 'Quedas de cliente', 'Portas instáveis', 'Projeção 30 dias']) {
        expect(find.text(r), findsWidgets, reason: r);
      }
      await abreUltimos(t);
      expect(find.text('Switch Teste · Porta 5'), findsOneWidget);
      expect(find.text('Switch Teste'), findsOneWidget); // sem porta: só o nome
      expect(find.text('PoE religado na porta'), findsOneWidget);
      expect(find.text('Alta'), findsOneWidget);
      expect(find.text('Média'), findsOneWidget);
      expect(find.text('high'), findsNothing);
      expect(find.text('02/01 ${_hora('2020-01-02T12:30:00Z')}'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('abas alternam MKs e Switches', (t) async {
    await _show(t, altura: 6000);
    expect(find.text('Mudanças de configuração'), findsOneWidget);
    expect(find.text('Eventos ao longo do tempo'), findsNothing);
    await abaSwitches(t);
    expect(find.text('Eventos ao longo do tempo'), findsOneWidget);
    expect(find.text('Mudanças de configuração'), findsNothing);
    await t.tap(find.text('MKs'));
    await t.pump();
    expect(find.text('Mudanças de configuração'), findsOneWidget);
    expect(find.text('Eventos ao longo do tempo'), findsNothing);
  });

  testWidgets('1h só na aba Switches: pede periodo=1h e volta a 24h nas MKs', (t) async {
    final urls = await _show(t, sw: {'contagens': <String, int>{}, 'eventos': <Object>[]}, altura: 6000);
    expect(find.text('1 h'), findsNothing);
    await abaSwitches(t);
    await t.tap(find.text('1 h'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(urls.any((u) => u.path == '/api/eventos/switches' && u.queryParameters['periodo'] == '1h'), true);
    expect(find.text('—'), findsOneWidget);
    urls.clear();
    await t.tap(find.text('MKs'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('1 h'), findsNothing);
    expect(urls.any((u) => u.path == '/api/eventos/painel' && u.queryParameters['periodo'] == '24h'), true);
    expect(urls.any((u) => u.queryParameters['periodo'] == '1h'), false);
  });

  testWidgets('Switches sem eventos mostra o estado vazio', (t) async {
    await _show(t, sw: {'contagens': <String, int>{}, 'eventos': <Object>[]}, altura: 6000);
    await abaSwitches(t);
    await abreUltimos(t);
    expect(find.text('Nenhum evento de switch no período.'), findsOneWidget);
  });

  testWidgets('erro nos Switches não derruba o conteúdo das MKs', (t) async {
    await _show(t, swStatus: 500, sw: {'detail': 'x'}, altura: 6000);
    expect(find.text('Mudanças de configuração'), findsOneWidget);
    expect(find.text('Tentar de novo'), findsNothing);
    await abaSwitches(t);
    expect(find.text('x'), findsOneWidget);
  });

  testWidgets('recarga que falha limpa os dados antigos e mostra o erro', (t) async {
    await _show(t, swFalhaNaSegunda: true, altura: 6000);
    await abaSwitches(t);
    expect(find.text('Eventos ao longo do tempo'), findsOneWidget);
    await t.tap(find.text('7 dias'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Eventos ao longo do tempo'), findsNothing);
    expect(find.text('Quedas de cliente'), findsNothing);
    expect(find.text('x'), findsOneWidget);
  });

  testWidgets('erro nas MKs não derruba a aba Switches', (t) async {
    await _show(t, corpo: {'detail': 'x'}, status: 500, altura: 6000);
    expect(find.text('Tentar de novo'), findsOneWidget);
    await abaSwitches(t);
    expect(find.text('Eventos ao longo do tempo'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('aba Switches em 360 px sem overflow (${b.name})', (t) async {
      await _show(t, b: b, largura: 360, altura: 7000);
      await abaSwitches(t);
      expect(find.text('Eventos ao longo do tempo'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}

String _hora(String iso) {
  final d = DateTime.parse(iso).toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

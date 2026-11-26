import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/mapa_ataques.dart';

http.Response _json(Object o, [int code = 200]) =>
    http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _ataque({bool sucesso = false}) => {
      'ip': '203.0.113.9', 'pais': 'CN', 'pais_nome': 'China', 'lat': 35.0, 'lon': 105.0,
      'mk_nome': 'MK Feed', 'via': 'ssh', 'n': 3, 'sucesso': sucesso,
      'quando': '2026-11-25T12:00:00+00:00', 'usuario': 'admin',
    };

Map<String, dynamic> _painel({List<Map<String, dynamic>> logins = const [], List<Map<String, dynamic>>? paises}) => {
      'periodo': '24h',
      'resumo': <String, int>{},
      'serie_hora': <Object>[],
      'blocos': {
        'acesso': {
          'total': 5,
          'por_mk': <Object>[],
          'top_ips': [
            {'ip': '203.0.113.9', 'n': 5, 'pais': 'CN', 'pais_nome': 'China'},
          ],
          'por_via': {'ssh': 4, 'winbox': 1},
          'top_paises': paises ??
              [
                {'pais': 'CN', 'pais_nome': 'China', 'n': 5},
              ],
          'logins_externos': logins,
        },
      },
      'por_mk': <Object>[],
      'atencao': <Object>[],
      'incidentes': <Object>[],
      'config': <Object>[],
    };

class _Servidor {
  int feedStatus = 200;
  int chamadasFeed = 0;
  int descartados = 0;
  bool travarPrimeira = false;
  List<Map<String, dynamic>> ataques = [];
  List<Map<String, dynamic>> logins = [];
  List<Map<String, dynamic>>? paises;

  ApiClient get api => ApiClient(
        client: MockClient((req) async {
          if (req.url.path == '/api/eventos/ataques') {
            if (chamadasFeed++ == 0 && travarPrimeira) return Completer<http.Response>().future; // nunca responde
            return feedStatus == 200
                ? _json({'cursor': 'c1', 'ataques': ataques, 'descartados': descartados})
                : _json({'detail': 'x'}, feedStatus);
          }
          if (req.url.path == '/api/eventos/painel') return _json(_painel(logins: logins, paises: paises));
          return http.Response('', 404);
        }),
      );
}

Future<void> _mostrar(WidgetTester t, _Servidor s, {bool tv = false, VoidCallback? aoExpirar}) async {
  t.view.physicalSize = const Size(1400, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(Brightness.dark),
    home: Scaffold(
      body: MapaAtaques(api: s.api, tv: tv, aoExpirarSessao: aoExpirar, intervalo: const Duration(seconds: 1)),
    ),
  ));
  await t.pump();
  await t.pump();
}

void main() {
  abaOculta();
  testWidgets('desenhaLinhaDoFeed', (t) async {
    final s = _Servidor()..ataques = [_ataque()];
    await _mostrar(t, s);
    final st = t.state<MapaAtaquesState>(find.byType(MapaAtaques));
    expect(st.linhasAtivas, 1);
  });

  testWidgets('indicadorSemDados', (t) async {
    final s = _Servidor()..feedStatus = 500;
    await _mostrar(t, s);
    expect(find.text('● ao vivo'), findsOneWidget);
    for (var i = 0; i < 31; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.textContaining('sem dados há'), findsOneWidget);
    expect(find.text('● ao vivo'), findsNothing);
    s.feedStatus = 200;
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('● ao vivo'), findsOneWidget);
    expect(find.textContaining('sem dados há'), findsNothing);
  });

  testWidgets('avisoLoginAceito', (t) async {
    final s = _Servidor()
      ..logins = [
        {'mk_id': 'a', 'nome': 'MK Alfa', 'usuario': 'admin', 'ip': '198.51.100.7', 'via': 'winbox',
         'quando': '2026-11-25T10:00:00+00:00', 'pais_nome': 'Rússia'},
      ];
    await _mostrar(t, s);
    expect(find.textContaining('MK Alfa'), findsOneWidget);
    await t.tap(find.text('Ciente'));
    await t.pump();
    expect(find.textContaining('MK Alfa'), findsNothing);
    // a recarga do painel não traz de volta o que já foi visto
    await t.pump(const Duration(seconds: 61));
    expect(find.textContaining('MK Alfa'), findsNothing);
  });

  testWidgets('cienteSobreviveAoReabrir', (t) async {
    final s = _Servidor()
      ..logins = [
        {'mk_id': 'b', 'nome': 'MK Beta', 'usuario': 'root', 'ip': '198.51.100.8', 'via': 'ssh',
         'quando': '2026-11-25T11:00:00+00:00', 'pais_nome': null},
      ];
    await _mostrar(t, s);
    await t.tap(find.text('Ciente'));
    await t.pump();
    await t.pumpWidget(const SizedBox());
    await _mostrar(t, s);
    expect(find.textContaining('MK Beta'), findsNothing);
  });

  testWidgets('rotuloComNomeDaMk', (t) async {
    final s = _Servidor()..ataques = [_ataque()];
    await _mostrar(t, s);
    await t.pump(const Duration(milliseconds: 100));
    final st = t.state<MapaAtaquesState>(find.byType(MapaAtaques));
    expect(st.rotulosDesenhados, contains('MK Feed'));
  });

  testWidgets('rotuloSoDaLinhaCheiaMaisRecente', (t) async {
    final s = _Servidor()
      ..ataques = [
        {..._ataque(), 'mk_nome': 'MK Antiga'},
        {..._ataque(), 'mk_nome': 'MK Nova'},
      ];
    await _mostrar(t, s);
    s.ataques = []; // só o 1º lote: as duas linhas saem em 0 s e 0,5 s
    final st = t.state<MapaAtaquesState>(find.byType(MapaAtaques));
    await t.pump(const Duration(milliseconds: 1600)); // Antiga cheia, Nova ainda viaja
    expect(st.rotulosDesenhados, unorderedEquals(['MK Antiga', 'MK Nova']));
    await t.pump(const Duration(milliseconds: 600)); // as duas cheias ao mesmo tempo
    expect(st.rotulosDesenhados, ['MK Nova']);
  });

  testWidgets('contadorDescartados', (t) async {
    final s = _Servidor();
    await _mostrar(t, s);
    expect(find.textContaining(RegExp(r'^\+\d')), findsNothing);
    await t.pumpWidget(const SizedBox());
    final s2 = _Servidor()..ataques = [for (var i = 0; i < 61; i++) _ataque()];
    await _mostrar(t, s2);
    expect(find.text('+1'), findsOneWidget);
    // só o último lote conta: zera na consulta seguinte e soma o que o servidor descartou
    s2.ataques = [];
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(find.textContaining(RegExp(r'^\+\d')), findsNothing);
    s2.descartados = 3;
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(find.text('+3'), findsOneWidget);
  });

  testWidgets('consultaPresaExpiraEVolta', (t) async {
    final s = _Servidor()
      ..travarPrimeira = true
      ..ataques = [_ataque()];
    await _mostrar(t, s);
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(s.chamadasFeed, greaterThan(1));
    expect(t.state<MapaAtaquesState>(find.byType(MapaAtaques)).linhasAtivas, greaterThan(0));
  });

  testWidgets('avisoDoFeed', (t) async {
    final s = _Servidor()..ataques = [_ataque(sucesso: true)];
    await _mostrar(t, s);
    expect(find.textContaining('MK Feed'), findsOneWidget);
  });

  testWidgets('sessaoExpiradaChamaCallback', (t) async {
    final s = _Servidor()..feedStatus = 401;
    var n = 0;
    await _mostrar(t, s, aoExpirar: () => n++);
    await t.pump(const Duration(seconds: 3));
    expect(n, 1);
  });

  testWidgets('rodapeSoNaTv', (t) async {
    await _mostrar(t, _Servidor());
    expect(find.text('TOP PAÍSES'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await _mostrar(t, _Servidor(), tv: true);
    expect(find.text('TOP PAÍSES'), findsOneWidget);
    expect(find.text('China'), findsWidgets);
  });

  testWidgets('rodapeAguentaCampoFaltando', (t) async {
    await _mostrar(t, _Servidor()..paises = [{'pais': 'AR'}], tv: true);
    expect(t.takeException(), isNull);
    expect(find.text('AR'), findsOneWidget);
  });

  testWidgets('creditoDbIp', (t) async {
    await _mostrar(t, _Servidor());
    expect(find.text('IP data by DB-IP'), findsOneWidget);
  });

  testWidgets('temaClaroRenderiza', (t) async {
    t.view.physicalSize = const Size(800, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: tradeTheme(Brightness.light),
      home: Scaffold(body: MapaAtaques(api: _Servidor().api, tv: true)),
    ));
    await t.pump();
    expect(t.takeException(), isNull);
  });
}

void abaOculta() {
  testWidgets('abaOcultaPulaConsulta', (t) async {
    final s = _Servidor();
    var visivel = false;
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: tradeTheme(Brightness.dark),
      home: Scaffold(body: MapaAtaques(api: s.api, intervalo: const Duration(seconds: 1), visivel: () => visivel)),
    ));
    await t.pump();
    await t.pump(const Duration(seconds: 3));
    expect(s.chamadasFeed, 0);
    visivel = true;
    await t.pump(const Duration(seconds: 1));
    expect(s.chamadasFeed, greaterThan(0));
    await t.pumpWidget(const SizedBox());
  });
}

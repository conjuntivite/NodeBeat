import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/ataques/paletas.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/widgets/ataques_tv.dart';
import 'package:nodebeat/widgets/common.dart';
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
  int painelStatus = 200;
  int chamadasFeed = 0;
  int descartados = 0;
  bool travarPrimeira = false;
  List<Map<String, dynamic>> ataques = [];
  List<Map<String, dynamic>> logins = [];
  List<Map<String, dynamic>>? paises;
  Duration atrasoPainel = Duration.zero;

  ApiClient get api => ApiClient(
        client: MockClient((req) async {
          // TV pública: mesmos dados, sem `usuario` (campos fechados do servidor)
          final tv = req.url.path.startsWith('/api/tv/');
          if (req.url.path == '/api/eventos/ataques' || req.url.path == '/api/tv/ataques') {
            if (chamadasFeed++ == 0 && travarPrimeira) return Completer<http.Response>().future; // nunca responde
            return feedStatus == 200
                ? _json({'cursor': 'c1', 'ataques': [for (final a in ataques) tv ? ({...a}..remove('usuario')) : a], 'descartados': descartados})
                : _json({'detail': 'x'}, feedStatus);
          }
          if (req.url.path == '/api/eventos/painel') {
            if (atrasoPainel > Duration.zero) await Future<void>.delayed(atrasoPainel); // o painel real leva ~12 s com cache frio
            return _json(_painel(logins: logins, paises: paises), painelStatus);
          }
          if (req.url.path == '/api/tv/tops') {
            if (atrasoPainel > Duration.zero) await Future<void>.delayed(atrasoPainel);
            final semUsuario = [for (final l in logins) {...l}..remove('usuario')..remove('mk_id')];
            return _json((_painel(logins: semUsuario, paises: paises)['blocos'] as Map)['acesso'], painelStatus);
          }
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
    expect(find.text('ao vivo'), findsOneWidget);
    for (var i = 0; i < 31; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.textContaining('sem dados há'), findsOneWidget);
    expect(find.text('ao vivo'), findsNothing);
    s.feedStatus = 200;
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('ao vivo'), findsOneWidget);
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

  testWidgets('faixasLimitadasComCienteEmTodos', (t) async {
    final s = _Servidor()
      ..logins = [
        for (var i = 1; i <= 5; i++)
          {'mk_id': 'm$i', 'nome': 'MK Lote$i', 'usuario': 'admin', 'ip': '198.51.100.$i', 'via': 'ssh',
           'quando': '2026-11-25T1$i:00:00+00:00', 'pais_nome': null},
      ];
    await _mostrar(t, s);
    // só as 2 mais recentes viram faixa; o resto vira um resumo
    expect(find.textContaining('MK Lote5'), findsOneWidget);
    expect(find.textContaining('MK Lote4'), findsOneWidget);
    expect(find.textContaining('MK Lote3'), findsNothing);
    expect(find.text('+3 outros logins de fora aceitos'), findsOneWidget);
    await t.tap(find.text('Ciente em todos'));
    await t.pump();
    expect(find.textContaining('MK Lote'), findsNothing);
    expect(find.textContaining('outros logins'), findsNothing);
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

  testWidgets('avisoTvSemUsuario', (t) async {
    final s = _Servidor()..ataques = [{..._ataque(sucesso: true), 'ip': '203.0.113.5'}..remove('usuario')];
    await _mostrar(t, s, tv: true);
    expect(find.textContaining('Login de fora aceito: MK Feed · 203.0.113.5'), findsOneWidget);
    expect(find.textContaining('· ?'), findsNothing);
  });

  testWidgets('sessaoExpiradaChamaCallback', (t) async {
    final s = _Servidor()..feedStatus = 401;
    var n = 0;
    await _mostrar(t, s, aoExpirar: () => n++);
    await t.pump(const Duration(seconds: 3));
    expect(n, 1);
  });

  testWidgets('colunaTopsNaTv', (t) async {
    await _mostrar(t, _Servidor());
    expect(find.byType(ColunaTops), findsNothing);
    await t.pumpWidget(const SizedBox());
    await _mostrar(t, _Servidor(), tv: true);
    final coluna = find.byType(ColunaTops);
    expect(find.descendant(of: coluna, matching: find.text('TOP PAÍSES')), findsOneWidget);
    expect(find.descendant(of: coluna, matching: find.text('China')), findsOneWidget);
    expect(find.descendant(of: coluna, matching: find.text('TOP TENTATIVAS')), findsOneWidget);
    expect(find.descendant(of: coluna, matching: find.text('203.0.113.9')), findsOneWidget);
    expect(find.descendant(of: coluna, matching: find.text('TOP TIPOS DE ACESSO')), findsOneWidget);
    expect(find.descendant(of: coluna, matching: find.text('SSH')), findsOneWidget);
  });

  testWidgets('colunaAguentaCampoFaltando', (t) async {
    await _mostrar(t, _Servidor()..paises = [{'pais': 'AR'}], tv: true);
    expect(t.takeException(), isNull);
    expect(find.text('AR'), findsOneWidget);
  });

  testWidgets('listaAoVivoNaTv', (t) async {
    await _mostrar(t, _Servidor()..ataques = [_ataque()]);
    expect(find.byType(ListaAoVivo), findsNothing);
    await t.pumpWidget(const SizedBox());
    await _mostrar(t, _Servidor()..ataques = [_ataque()], tv: true);
    final lista = find.byType(ListaAoVivo);
    expect(find.descendant(of: lista, matching: find.text('MK Feed')), findsOneWidget);
    expect(find.descendant(of: lista, matching: find.text('China')), findsOneWidget);
    expect(find.descendant(of: lista, matching: find.text('203.0.113.9')), findsOneWidget);
    expect(find.descendant(of: lista, matching: find.text('SSH')), findsOneWidget);
    expect(find.descendant(of: lista, matching: find.text('Tentativa')), findsOneWidget);
  });

  testWidgets('listaMostraMultiplicador', (t) async {
    await _mostrar(t, _Servidor()..ataques = [_ataque(), {..._ataque(), 'n': 1, 'mk_nome': 'MK Um'}], tv: true);
    final lista = find.byType(ListaAoVivo);
    expect(find.descendant(of: lista, matching: find.text('×3')), findsOneWidget);
    expect(find.descendant(of: lista, matching: find.text('×1')), findsNothing);
  });

  testWidgets('listaMarcaAcessoAceito', (t) async {
    await _mostrar(t, _Servidor()..ataques = [_ataque(sucesso: true)], tv: true);
    expect(find.descendant(of: find.byType(ListaAoVivo), matching: find.text('Acesso aceito')), findsOneWidget);
  });

  testWidgets('listaGuardaSo8', (t) async {
    final s = _Servidor()
      ..ataques = [
        for (var i = 0; i < 12; i++) {..._ataque(), 'mk_nome': 'MK $i', 'quando': '2026-11-25T12:00:${two(i)}+00:00'},
      ];
    await _mostrar(t, s, tv: true);
    final st = t.state<MapaAtaquesState>(find.byType(MapaAtaques));
    expect(st.recentes.length, 8);
    expect(st.recentes.first.mkNome, 'MK 11');
  });

  testWidgets('creditoDbIp', (t) async {
    await _mostrar(t, _Servidor());
    expect(find.text('IP data by DB-IP'), findsOneWidget);
  });

  testWidgets('tvMapaPegaOQueSobraDaLista', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: tradeTheme(Brightness.dark),
      home: Scaffold(
        body: MapaAtaques(api: (_Servidor()..ataques = [for (var i = 0; i < 8; i++) {..._ataque(), 'mk_nome': 'MK $i'}]).api, tv: true),
      ),
    ));
    await t.pump();
    await t.pump();
    final lista = t.getSize(find.ancestor(of: find.byType(ListaAoVivo), matching: find.byType(SingleChildScrollView))).height; // área ocupada (já limitada a 40%)
    final mapa = t.getSize(find.ancestor(of: find.text('IP data by DB-IP'), matching: find.byType(Stack)).first).height;
    expect(lista, greaterThan(0));
    // 8 linhas inteiras: altura natural da lista cabe no limite de 40%
    expect(t.getSize(find.byType(ListaAoVivo)).height, lessThanOrEqualTo(lista + 0.01));
    expect(lista, lessThanOrEqualTo(1080 * 0.4));
    expect(lista + mapa, closeTo(1080, 4));
  });

  testWidgets('tvBaixaNaoEstoura', (t) async {
    final s = _Servidor()
      ..logins = [
        for (var i = 1; i <= 3; i++)
          {'mk_id': 'm$i', 'nome': 'MK Lote$i', 'usuario': 'admin', 'ip': '198.51.100.$i', 'via': 'ssh',
           'quando': '2026-11-25T1$i:00:00+00:00', 'pais_nome': null},
      ]
      ..ataques = [for (var i = 0; i < 8; i++) {..._ataque(sucesso: i.isEven), 'mk_nome': 'MK $i'}];
    await _mostrar(t, s, tv: true);
    t.view.physicalSize = const Size(1280, 600);
    await t.pump();
    expect(find.byType(ListaAoVivo), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('servicoUsaFgPrimaryEPontoColorido', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: tradeTheme(Brightness.light),
      home: Scaffold(body: MapaAtaques(api: (_Servidor()..ataques = [_ataque()]).api, tv: true)),
    ));
    await t.pump();
    await t.pump();
    final tk = TradeTokens.light;
    final txt = t.widget<Text>(find.descendant(of: find.byType(ListaAoVivo), matching: find.text('SSH')));
    expect(txt.style!.color, tk.fgPrimary);
    expect(
        find.descendant(
            of: find.byType(ListaAoVivo),
            matching: find.byWidgetPredicate((w) =>
                w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == corVia(paletaPadrao(Brightness.light), 'ssh'))),
        findsOneWidget);
  });

  // o painel pode levar mais que 3x o intervalo do feed; o limite é o intervalo do rodapé
  testWidgets('painelLentoAindaPreencheColuna', (t) async {
    await _mostrar(t, _Servidor()..atrasoPainel = const Duration(seconds: 5), tv: true);
    expect(find.text('Aguardando dados'), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
    expect(find.text('Aguardando dados'), findsNothing);
    expect(find.text('TOP PAÍSES'), findsOneWidget);
  });

  testWidgets('colunaVaziaAguardandoDados', (t) async {
    await _mostrar(t, _Servidor()..painelStatus = 500, tv: true);
    expect(find.text('Aguardando dados'), findsOneWidget);
  });

  testWidgets('temaClaroRenderiza', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: tradeTheme(Brightness.light),
      home: Scaffold(
        body: MapaAtaques(api: (_Servidor()..ataques = [for (var i = 0; i < 8; i++) {..._ataque(sucesso: i.isEven), 'mk_nome': 'MK $i'}]).api, tv: true),
      ),
    ));
    await t.pump();
    await t.pump();
    expect(find.byType(ListaAoVivo), findsOneWidget);
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

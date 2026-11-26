import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/ataques/aba.dart';
import 'package:nodebeat/ataques/paletas.dart';
import 'package:nodebeat/main.dart';
import 'package:nodebeat/screens/login.dart';
import 'package:nodebeat/screens/mapa_ataques_tv.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/widgets/mapa_ataques.dart';

const _json = {'content-type': 'application/json'};

// Só /api/tv/* responde; o resto é 401 (TV sem sessão).
MockClient _semSessao(List<String> paths) => MockClient((req) async {
      paths.add(req.url.path);
      if (req.url.path == '/api/tv/ataques') return http.Response('{"cursor":"c1","ataques":[],"descartados":0}', 200, headers: _json);
      if (req.url.path == '/api/tv/tops') {
        return http.Response('{"total":0,"top_ips":[],"top_paises":[],"por_via":{},"logins_externos":[]}', 200, headers: _json);
      }
      return http.Response('{"detail":"x"}', 401, headers: _json);
    });

void main() {
  setUp(() => themeMode.value = ThemeMode.light);
  tearDown(() => themeMode.value = ThemeMode.light);

  test('tvNaoCarregaSessao', () {
    expect(ehTv(Uri.parse('https://x/#/tv')), isTrue);
    expect(ehTv(Uri.parse('https://x/#/tv?a=1')), isTrue);
    expect(ehTv(Uri.parse('https://x/#/painel')), isFalse);
    expect(ehTv(Uri.parse('https://x/#/tvx')), isFalse);
    expect(ehTv(Uri.parse('https://x/')), isFalse);
  });

  testWidgets('tvAbreSemLogin', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final paths = <String>[];
    await t.pumpWidget(NodeBeatApp(api: ApiClient(client: _semSessao(paths))));
    t.state<NavigatorState>(find.byType(Navigator)).pushReplacementNamed('/tv');
    await t.pump();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(MapaAtaquesTvScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(paths, contains('/api/tv/ataques'));
    expect(paths, contains('/api/tv/tops'));
    expect(paths.where((p) => p.startsWith('/api/eventos/')), isEmpty);
    await t.pumpWidget(const SizedBox());
  });

  Widget tv(ApiClient api) => MaterialApp(theme: tradeTheme(Brightness.light), home: MapaAtaquesTvScreen(api: api));
  PaletaMapa paletaDoMapa(WidgetTester t) => t.widget<MapaAtaques>(find.byType(MapaAtaques)).paleta!;

  testWidgets('tvGuardaPaleta', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    salvarPaletaTv('ardosia');
    final api = ApiClient(client: _semSessao([]));
    await t.pumpWidget(tv(api));
    await t.pump();
    expect(paletaDoMapa(t).id, 'ardosia');
    await t.tap(find.byTooltip('Paleta do mapa'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Oceano'), findsOneWidget);
    await t.tap(find.text('Oceano'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(paletaTvSalva(), 'oceano');
    expect(paletaDoMapa(t).id, 'oceano');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(tv(api));
    await t.pump();
    expect(paletaDoMapa(t).id, 'oceano');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('trocarPaletaRepinta', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    salvarPaletaTv('ardosia');
    await t.pumpWidget(tv(ApiClient(client: _semSessao([]))));
    await t.pump();
    Finder fundo(Color c) => find.descendant(of: find.byType(MapaAtaques), matching: find.byWidgetPredicate((w) => w is ColoredBox && w.color == c));
    expect(fundo(paletaPorId('ardosia').fundo), findsWidgets);
    await t.tap(find.byTooltip('Paleta do mapa'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.text('Oceano'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(fundo(paletaPorId('oceano').fundo), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('tvPintaComAPaleta', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    salvarPaletaTv('oceano');
    await t.pumpWidget(tv(ApiClient(client: _semSessao([]))));
    await t.pump();
    final p = paletaPorId('oceano');
    expect(t.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, p.fundo);
    expect(t.widget<Text>(find.text('Ataques às MKs')).style!.color, p.texto);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('tvSemBotaoDeTema', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(tv(ApiClient(client: _semSessao([]))));
    await t.pump();
    expect(find.byType(ThemeToggle), findsNothing);
    expect(find.byTooltip('Paleta do mapa'), findsOneWidget);
    // botão visível sem depender da fonte de ícones
    expect(find.descendant(of: find.byTooltip('Paleta do mapa'), matching: find.text('Paleta')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('tvIgnoraTemaGlobal', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    salvarPaletaTv('ardosia');
    await t.pumpWidget(tv(ApiClient(client: _semSessao([]))));
    await t.pump();
    expect(themeMode.value, ThemeMode.light);
    expect(Theme.of(t.element(find.byType(MapaAtaques))).brightness, Brightness.dark);
    expect(tokensOf(t.element(find.byType(MapaAtaques))).bgSurface, paletaPorId('ardosia').painel);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('foraDaTvTokensIguais', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(theme: tradeTheme(Brightness.light), home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    expect(identical(tokensOf(ctx), TradeTokens.light), isTrue);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/ataques/aba.dart';
import 'package:nodebeat/main.dart';
import 'package:nodebeat/screens/login.dart';
import 'package:nodebeat/screens/mapa_ataques_tv.dart';
import 'package:nodebeat/theme/theme.dart';
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

  testWidgets('tvGuardaTema', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    salvarTemaTv('escuro');
    final api = ApiClient(client: _semSessao([]));
    await t.pumpWidget(ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, _) => MaterialApp(
        theme: tradeTheme(Brightness.light),
        darkTheme: tradeTheme(Brightness.dark),
        themeMode: mode,
        home: MapaAtaquesTvScreen(api: api),
      ),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500)); // AnimatedTheme
    expect(themeMode.value, ThemeMode.dark);
    Brightness b() => Theme.of(t.element(find.byType(MapaAtaques))).brightness;
    expect(b(), Brightness.dark);
    await t.tap(find.byType(ThemeToggle));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(b(), Brightness.light);
    expect(temaTvSalvo(), 'claro');
    await t.pumpWidget(const SizedBox());
  });
}

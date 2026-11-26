import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/main.dart';
import 'package:nodebeat/screens/login.dart';
import 'package:nodebeat/screens/mapa_ataques_tv.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/mapa_ataques.dart';

void main() {
  testWidgets('tvVaiProLoginEVolta', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var logado = false;
    final mock = MockClient((req) async {
      if (req.url.path == '/api/auth/login') {
        logado = true;
        return http.Response('', 204);
      }
      if (req.url.path == '/api/auth/me') return http.Response('{"detail":"x"}', 401);
      return logado ? http.Response('{"cursor":null,"ataques":[],"descartados":0}', 200, headers: {'content-type': 'application/json'}) : http.Response('{"detail":"x"}', 401);
    });
    await t.pumpWidget(NodeBeatApp(api: ApiClient(client: mock)));
    // chega na TV pela rota (como a aba aberta pelo popup)
    final nav = t.state<NavigatorState>(find.byType(Navigator));
    nav.pushReplacementNamed('/eventos/mapa');
    await t.pump();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(LoginScreen), findsOneWidget);
    await t.enterText(find.byType(TextField).at(0), 'admin');
    await t.enterText(find.byType(TextField).at(1), 'senha');
    await t.tap(find.text('Entrar'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(MapaAtaquesTvScreen), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('tvSegueTemaEAlterna', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(() => themeMode.value = ThemeMode.light);
    themeMode.value = ThemeMode.light;
    final api = ApiClient(client: MockClient((_) async => http.Response('{"detail":"x"}', 500)));
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
    Brightness b() => Theme.of(t.element(find.byType(MapaAtaques))).brightness;
    expect(b(), Brightness.light);
    await t.tap(find.byTooltip('Tema escuro'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500)); // AnimatedTheme
    expect(b(), Brightness.dark);
    await t.pumpWidget(const SizedBox());
  });
}

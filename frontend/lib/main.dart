import 'package:material_ui/material_ui.dart';

import 'api/client.dart';
import 'screens/login.dart';
import 'screens/painel.dart';
import 'theme/theme.dart';

void main() => runApp(NodeBeatApp(api: ApiClient()));

class NodeBeatApp extends StatelessWidget {
  const NodeBeatApp({super.key, required this.api});
  final ApiClient api;

  // Rotas novas (/mk/:id, /mk/novo...) entram neste switch.
  Route<dynamic>? _route(RouteSettings s) {
    final page = switch (s.name) {
      '/painel' => const PainelScreen(),
      _ => LoginScreen(api: api),
    };
    return MaterialPageRoute(settings: s, builder: (_) => page);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
        valueListenable: themeMode,
        builder: (_, mode, _) => MaterialApp(
          title: 'NodeBeat',
          debugShowCheckedModeBanner: false,
          theme: tradeTheme(Brightness.light),
          darkTheme: tradeTheme(Brightness.dark),
          themeMode: mode,
          initialRoute: '/login',
          onGenerateRoute: _route,
        ),
      );
}

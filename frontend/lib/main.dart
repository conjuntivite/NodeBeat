import 'package:material_ui/material_ui.dart';

import 'api/client.dart';
import 'screens/login.dart';
import 'screens/dashboard.dart';
import 'screens/faixas.dart';
import 'screens/mk_detail.dart';
import 'screens/mk_form.dart';
import 'screens/preparar_mk.dart';
import 'theme/theme.dart';

void main() => runApp(NodeBeatApp(api: ApiClient()));

class NodeBeatApp extends StatelessWidget {
  const NodeBeatApp({super.key, required this.api});
  final ApiClient api;

  Route<dynamic>? _route(RouteSettings s) {
    final seg = Uri.parse(s.name ?? '').pathSegments;
    final page = switch (seg) {
      ['painel'] => DashboardScreen(api: api),
      ['faixas'] => FaixasScreen(api: api),
      ['preparar-mk'] => PrepararMkScreen(api: api),
      ['mk', 'novo'] => MkFormScreen(api: api),
      ['mk', final id] => MkDetailScreen(api: api, id: id, chooseInterfaces: s.arguments == true),
      ['mk', final id, 'editar'] => MkFormScreen(api: api, id: id),
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
          // Recarregar em #/painel não deixa o /login por baixo; em #/mk/<id> o painel fica por
          // baixo e reabre a MK (sem ele não há som nem voltar).
          onGenerateInitialRoutes: (name) => switch (Uri.parse(name).pathSegments) {
            ['mk', final id] when id != 'novo' => [
                MaterialPageRoute(settings: const RouteSettings(name: '/painel'), builder: (_) => DashboardScreen(api: api, abrir: id)),
              ],
            _ => [_route(RouteSettings(name: name))!],
          },
        ),
      );
}

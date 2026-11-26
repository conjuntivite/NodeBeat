import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/main.dart';
import 'package:nodebeat/screens/dashboard.dart';
import 'package:nodebeat/screens/login.dart';

Future<void> _enter(WidgetTester t, int status) async {
  final mock = MockClient((req) async {
    if (req.url.path == '/api/auth/me') return http.Response('{"detail":"Não autenticado"}', 401);
    expect(req.method, 'POST');
    expect(req.url.path, '/api/auth/login');
    expect(jsonDecode(req.body), {'usuario': 'admin', 'senha': 'senha'});
    return http.Response('', status);
  });
  await t.pumpWidget(NodeBeatApp(api: ApiClient(client: mock)));
  await t.enterText(find.byType(TextField).at(0), 'admin');
  await t.enterText(find.byType(TextField).at(1), 'senha');
  await t.tap(find.text('Entrar'));
  await t.pump(); // sem pumpAndSettle: o painel tem animação em loop
  await t.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('401 mostra erro e permanece no login', (t) async {
    await _enter(t, 401);
    expect(find.text('Usuário ou senha inválidos'), findsOneWidget);
    expect(find.text('Entrar'), findsOneWidget);
  });

  testWidgets('429 mostra aviso de espera', (t) async {
    await _enter(t, 429);
    expect(find.text('Muitas tentativas. Aguarde 15 minutos.'), findsOneWidget);
  });

  testWidgets('204 navega para /painel', (t) async {
    await _enter(t, 204);
    expect(find.byType(DashboardScreen), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  loginDestino();
}

void loginDestino() {
  testWidgets('loginVaiParaDestino', (t) async {
    final mock = MockClient((req) async => req.url.path == '/api/auth/me' ? http.Response('{}', 401) : http.Response('', 204));
    final rotas = <String?>[];
    await t.pumpWidget(MaterialApp(
      onGenerateRoute: (s) {
        rotas.add(s.name);
        return MaterialPageRoute(settings: s, builder: (_) => s.name == '/login' ? LoginScreen(api: ApiClient(client: mock), depois: '/eventos/mapa') : const Text('destino'));
      },
      initialRoute: '/login',
    ));
    await t.enterText(find.byType(TextField).at(0), 'admin');
    await t.enterText(find.byType(TextField).at(1), 'senha');
    await t.tap(find.text('Entrar'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(rotas.last, '/eventos/mapa');
  });
}

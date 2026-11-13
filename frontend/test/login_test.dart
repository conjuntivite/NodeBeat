import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/main.dart';
import 'package:nodebeat/screens/dashboard.dart';

Future<void> _enter(WidgetTester t, int status) async {
  final mock = MockClient((req) async {
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
}

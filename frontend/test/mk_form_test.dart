import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/mk_form.dart';
import 'package:nodebeat/theme/theme.dart';

Future<void> _show(WidgetTester t, MockClient mock, {String? id}) async {
  t.view.physicalSize = const Size(900, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(Brightness.light),
    home: MkFormScreen(api: ApiClient(client: mock), id: id),
  ));
  await t.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  testWidgets('422 com erro em ip_tunel aparece abaixo do campo', (t) async {
    await _show(
        t,
        MockClient((req) async => http.Response(
            jsonEncode({'detail': [{'loc': ['body', 'ip_tunel'], 'msg': 'faixa de IP inválida'}]}), 422,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    await t.enterText(_field('Condomínio'), 'cliente-v7');
    await t.enterText(_field('IP no túnel'), '8.8.8.8');
    await t.enterText(_field('IP público'), '203.0.113.9');
    await t.enterText(_field('Usuário da API'), 'monitor');
    await t.enterText(_field('Senha da API'), 'segredo');
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    expect(find.text('faixa de IP inválida'), findsOneWidget);
  });

  testWidgets('edição com senha vazia não envia senha', (t) async {
    Map<String, dynamic>? sent;
    await _show(
        t,
        MockClient((req) async {
          if (req.method == 'PUT') {
            sent = jsonDecode(req.body);
            return http.Response('', 204);
          }
          return http.Response(
              jsonEncode({
                'id': 'x', 'nome': 'cliente-v7', 'ip_tunel': '10.0.0.2', 'ip_publico': '203.0.113.9',
                'usuario': 'monitor', 'interfaces_vigiadas': [], 'cert_sha256': null, 'estado': null,
              }),
              200);
        }),
        id: 'x');
    expect(find.text('deixe vazio para manter'), findsOneWidget);
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    expect(sent, isNotNull);
    expect(sent!.containsKey('senha'), false);
    expect(sent!['nome'], 'cliente-v7');
  });

  test('MkInput sem senha → senha null', () {
    final i = MkInput(nome: 'a', ipTunel: '10.0.0.2', ipPublico: '203.0.113.9', usuario: 'u');
    expect(i.senha, isNull);
  });
}

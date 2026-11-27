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
    expect(find.text('deixe vazio para manter'), findsNWidgets(2));
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    expect(sent, isNotNull);
    expect(sent!.containsKey('senha'), false);
    expect(sent!['nome'], 'cliente-v7');
  });

  MockClient editMock(bool temRw, void Function(Map<String, dynamic>) onPut) => MockClient((req) async {
        if (req.method == 'PUT') {
          onPut(jsonDecode(req.body));
          return http.Response('', 204);
        }
        return http.Response(
            jsonEncode({
              'id': 'x', 'nome': 'cliente-v7', 'ip_tunel': '10.0.0.2', 'ip_publico': '203.0.113.9',
              'usuario': 'monitor', 'interfaces_vigiadas': [], 'cert_sha256': null, 'estado': null, 'tem_rw': temRw,
            }),
            200);
      });

  testWidgets('senha de alterações vazia não envia senha_rw nem remover_rw', (t) async {
    Map<String, dynamic>? sent;
    await _show(t, editMock(true, (b) => sent = b), id: 'x');
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    expect(sent!.containsKey('senha_rw'), false);
    expect(sent!.containsKey('remover_rw'), false);
  });

  testWidgets('senha de alterações preenchida envia senha_rw', (t) async {
    Map<String, dynamic>? sent;
    await _show(t, editMock(false, (b) => sent = b), id: 'x');
    expect(find.text('Remover senha de alterações'), findsNothing);
    await t.enterText(_field('Senha de alterações (nodebeat-rw)'), 'nova-rw');
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    expect(sent!['senha_rw'], 'nova-rw');
  });

  testWidgets('remover senha de alterações envia remover_rw true', (t) async {
    Map<String, dynamic>? sent;
    await _show(t, editMock(true, (b) => sent = b), id: 'x');
    await t.tap(find.text('Remover senha de alterações'));
    await t.pumpAndSettle();
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    expect(sent!['remover_rw'], true);
    expect(sent!.containsKey('senha_rw'), false);
  });

  testWidgets('422 sem campo conhecido mostra a mensagem geral', (t) async {
    await _show(
        t,
        MockClient((req) async => http.Response(
            jsonEncode({'detail': [{'loc': ['body'], 'msg': 'Valor inválido'}]}), 422,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    await t.enterText(_field('Condomínio'), 'cliente-v7');
    await t.enterText(_field('IP no túnel'), '10.0.0.2');
    await t.enterText(_field('IP público'), '203.0.113.9');
    await t.enterText(_field('Usuário da API'), 'monitor');
    await t.enterText(_field('Senha da API'), 'segredo');
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    expect(find.text('Requisição inválida'), findsOneWidget);
  });

  test('MkInput sem senha → senha null', () {
    final i = MkInput(nome: 'a', ipTunel: '10.0.0.2', ipPublico: '203.0.113.9', usuario: 'u');
    expect(i.senha, isNull);
  });

  test('liberacoes aceita porta como texto e DELETE codifica a descricao', () async {
    String? delete;
    final api = ApiClient(client: MockClient((req) async {
      if (req.method == 'DELETE') {
        delete = req.url.toString();
        return http.Response('', 204);
      }
      return http.Response(
          jsonEncode({'liberacoes': [{'descricao': 'cam 1', 'protocolos': ['tcp'], 'porta_externa': '8080', 'ip_interno': '192.168.88.5', 'porta_interna': 80, 'wan': null, 'desativada': false}], 'via': 'tunel'}),
          200);
    }));
    final l = (await api.liberacoes('x')).single;
    expect((l.portaExterna, l.portaInterna), (8080, 80));
    await api.removerLiberacao('x', 'cam 1');
    expect(delete, contains('descricao=cam%201'));
  });

  test('trocarPeer lê policies_erro como lista', () async {
    ApiClient api(List<String> erro) => ApiClient(
        client: MockClient((req) async => http.Response(
            jsonEncode({'antigo': '203.0.113.1', 'novo': '203.0.113.2', 'confirmado': true, 'policies': [], 'policies_erro': erro, 'nome': 'x', 'via': 'tunel'}),
            200)));
    final ok = await api([]).trocarPeer('x', '*1', '203.0.113.2');
    expect((ok.confirmado, ok.via), (true, 'tunel'));
    expect(ok.policiesErro, isEmpty);
    expect((await api(['*3']).trocarPeer('x', '*1', '203.0.113.2')).policiesErro, ['*3']);
  });
}

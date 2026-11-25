import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/screens/usuarios.dart';
import 'package:nodebeat/sessao.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/shell.dart';

http.Response _json(Object o, [int code = 200]) =>
    http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json; charset=utf-8'});

const _senhaOk = 'senha-bem-longa-1';

Future<List<http.Request>> _show(
  WidgetTester t, {
  int listaStatus = 200,
  http.Response? respostaEscrita,
  double largura = 1000,
  Brightness b = Brightness.light,
}) async {
  t.view.physicalSize = Size(largura, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final vistos = <http.Request>[];
  final api = ApiClient(
    client: MockClient((req) async {
      vistos.add(req);
      if (req.method == 'GET' && req.url.path == '/api/usuarios') {
        return listaStatus == 200
            ? _json([
                {'usuario': 'admin', 'admin': true, 'criado_em': '2026-01-05T10:00:00+00:00'},
                {'usuario': 'maria', 'admin': false, 'criado_em': '2026-03-09T10:00:00+00:00'},
              ])
            : _json({'detail': 'Acesso restrito ao admin'}, listaStatus);
      }
      return respostaEscrita ?? http.Response('', 204);
    }),
  );
  apiSessao = api;
  usuarioAtual.value = Eu.fromJson({'usuario': 'admin', 'admin': true, 'tema': null});
  await t.pumpWidget(MaterialApp(theme: tradeTheme(b), home: UsuariosScreen(api: api)));
  await t.pump();
  await t.pump();
  return vistos;
}

void main() {
  setUp(() => usuarioAtual.value = null);

  testWidgets('item Usuários só aparece para admin', (t) async {
    Widget app() => MaterialApp(
          theme: tradeTheme(Brightness.light),
          home: const AppShell(ativo: 'mk', titulo: 'X', body: SizedBox()),
        );
    t.view.physicalSize = const Size(1000, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    usuarioAtual.value = Eu.fromJson({'usuario': 'u', 'admin': false});
    await t.pumpWidget(app());
    expect(find.byKey(const Key('nav-usuarios')), findsNothing);
    usuarioAtual.value = Eu.fromJson({'usuario': 'a', 'admin': true});
    await t.pump();
    expect(find.byKey(const Key('nav-usuarios')), findsOneWidget);
  });

  testWidgets('lista usuários com Selo Admin', (t) async {
    await _show(t);
    expect(find.text('maria'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget); // só o admin ganha selo
    expect(find.text('09/03/2026'), findsOneWidget);
  });

  testWidgets('403 mostra acesso restrito', (t) async {
    await _show(t, listaStatus: 403);
    expect(find.text('Acesso restrito ao admin'), findsOneWidget);
  });

  testWidgets('criar usuário envia POST normalizado', (t) async {
    final vistos = await _show(t);
    await t.tap(find.text('Novo usuário'));
    await t.pump();
    await t.enterText(find.widgetWithText(TextField, 'Usuário'), '  João ');
    await t.enterText(find.widgetWithText(TextField, 'Senha'), _senhaOk);
    await t.tap(find.byType(Checkbox));
    await t.tap(find.text('Salvar'));
    await t.pump();
    await t.pump();
    final post = vistos.singleWhere((r) => r.method == 'POST');
    expect(jsonDecode(post.body), {'usuario': 'joão', 'senha': _senhaOk, 'admin': true});
    expect(vistos.where((r) => r.method == 'GET').length, 2); // recarregou
  });

  testWidgets('senha curta não envia', (t) async {
    final vistos = await _show(t);
    await t.tap(find.text('Novo usuário'));
    await t.pump();
    await t.enterText(find.widgetWithText(TextField, 'Usuário'), 'joao');
    await t.enterText(find.widgetWithText(TextField, 'Senha'), 'curta');
    await t.tap(find.text('Salvar'));
    await t.pump();
    expect(vistos.where((r) => r.method == 'POST'), isEmpty);
    expect(find.text('A senha precisa ter no mínimo 12 caracteres'), findsOneWidget);
  });

  testWidgets('remover pede confirmação e envia DELETE', (t) async {
    final vistos = await _show(t);
    await t.tap(find.byTooltip('Remover usuário maria'));
    await t.pump();
    expect(vistos.where((r) => r.method == 'DELETE'), isEmpty);
    await t.tap(find.widgetWithText(FilledButton, 'Remover'));
    await t.pump();
    await t.pump();
    final del = vistos.singleWhere((r) => r.method == 'DELETE');
    expect(del.url.path, '/api/usuarios/maria');
  });

  testWidgets('409 mostra a mensagem da API', (t) async {
    await _show(t, respostaEscrita: _json({'detail': 'Precisa haver ao menos um admin'}, 409));
    await t.tap(find.byTooltip('Remover admin de admin'));
    await t.pump();
    await t.pump();
    expect(find.text('Precisa haver ao menos um admin'), findsOneWidget);
  });

  testWidgets('redefinir senha envia PUT', (t) async {
    final vistos = await _show(t);
    await t.tap(find.byTooltip('Redefinir senha de maria'));
    await t.pump();
    await t.enterText(find.byType(TextField), _senhaOk);
    await t.tap(find.text('Salvar'));
    await t.pump();
    final put = vistos.singleWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/usuarios/maria');
    expect(jsonDecode(put.body), {'senha': _senhaOk});
  });

  testWidgets('no celular, Minha conta fecha o menu antes do diálogo', (t) async {
    await _show(t, largura: 360);
    await t.tap(find.byTooltip('Menu'));
    await t.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    await t.tap(find.byTooltip('Minha conta'));
    await t.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    expect(find.text('Senha atual'), findsOneWidget);
  });

  testWidgets('Minha conta envia PUT /api/auth/senha', (t) async {
    final vistos = await _show(t);
    await t.tap(find.byTooltip('Minha conta'));
    await t.pump();
    await t.enterText(find.widgetWithText(TextField, 'Senha atual'), 'antiga');
    await t.enterText(find.widgetWithText(TextField, 'Nova senha'), _senhaOk);
    await t.enterText(find.widgetWithText(TextField, 'Confirmar'), 'outra-coisa-longa');
    await t.tap(find.text('Salvar'));
    await t.pump();
    expect(find.text('As senhas não conferem'), findsOneWidget);
    expect(vistos.where((r) => r.method == 'PUT'), isEmpty);
    await t.enterText(find.widgetWithText(TextField, 'Confirmar'), _senhaOk);
    await t.tap(find.text('Salvar'));
    await t.pump();
    await t.pump();
    final put = vistos.singleWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/auth/senha');
    expect(jsonDecode(put.body), {'atual': 'antiga', 'nova': _senhaOk});
    expect(find.text('Senha alterada'), findsOneWidget);
  });

  testWidgets('360 px sem estouro, tema escuro', (t) async {
    await _show(t, largura: 360, b: Brightness.dark);
    expect(find.text('maria'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}

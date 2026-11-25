import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/sessao.dart';
import 'package:nodebeat/theme/theme.dart';

ApiClient _api(List<http.Request> vistos, {String? tema = 'escuro', int status = 200}) => ApiClient(
      client: MockClient((req) async {
        vistos.add(req);
        if (req.url.path == '/api/auth/me') {
          return status == 200
              ? http.Response(jsonEncode({'usuario': 'admin', 'admin': true, 'tema': tema}), 200)
              : http.Response(jsonEncode({'detail': 'Não autenticado'}), status);
        }
        return http.Response('', 204);
      }),
    );

void main() {
  setUp(() {
    usuarioAtual.value = null;
    themeMode.value = ThemeMode.light;
  });

  test('carregarSessao aplica tema escuro', () async {
    await carregarSessao(_api([]));
    expect(themeMode.value, ThemeMode.dark);
    expect(usuarioAtual.value!.admin, isTrue);
  });

  test('tema null fica claro', () async {
    themeMode.value = ThemeMode.dark;
    await carregarSessao(_api([], tema: null));
    expect(themeMode.value, ThemeMode.light);
  });

  test('erro no me não quebra', () async {
    await carregarSessao(_api([], status: 401));
    expect(usuarioAtual.value, isNull);
  });

  testWidgets('ThemeToggle grava na API', (t) async {
    final vistos = <http.Request>[];
    await carregarSessao(_api(vistos, tema: 'claro'));
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: ThemeToggle())));
    await t.tap(find.byType(IconButton));
    await t.pump();
    final put = vistos.singleWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/auth/tema');
    expect(jsonDecode(put.body), {'tema': 'escuro'});
  });
}

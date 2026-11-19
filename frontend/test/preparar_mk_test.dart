import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/mk_script.dart';
import 'package:nodebeat/screens/preparar_mk.dart';
import 'package:nodebeat/theme/theme.dart';

http.Response _json(Object o) =>
    http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Future<List<String>> _show(WidgetTester t,
    {Map<String, dynamic> info = const {'ip_origem': '10.9.9.9', 'ips_publicos_sede': ['203.0.113.5']},
    Brightness b = Brightness.light}) async {
  t.view.physicalSize = const Size(1200, 3000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final copiado = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copiado.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  final api = ApiClient(client: MockClient((req) async => _json(info)));
  await t.pumpWidget(MaterialApp(theme: tradeTheme(b), home: PrepararMkScreen(api: api)));
  await t.pump();
  await t.pump();
  return copiado;
}

String _script(WidgetTester t) => t.widget<SelectableText>(find.byKey(const Key('script-preparar'))).data!;

void main() {
  testWidgets('mostra o script com os IPs do servidor e a senha mostrada na página', (t) async {
    await _show(t);
    final s = _script(t);
    expect(s, contains('"10.9.9.9"'));
    expect(s, contains('address=203.0.113.5 '));
    final senha = t.widget<SelectableText>(find.byKey(const Key('senha'))).data!;
    expect(senha, matches(RegExp(r'^[A-Za-z0-9]{20}$')));
    expect(s, contains('"$senha"'));
  });

  testWidgets('explica o que fazer quando a colagem quebra, nos dois scripts', (t) async {
    await _show(t);
    expect(find.textContaining('invalid value'), findsNWidgets(2));
  });

  testWidgets('Copiar põe o script no clipboard e avisa', (t) async {
    final copiado = await _show(t);
    await t.tap(find.byKey(const Key('copiar-preparar')));
    await t.pump();
    expect(copiado.single, _script(t));
    expect(find.text('Script copiado'), findsOneWidget);
  });

  testWidgets('Gerar outra senha troca a senha no script', (t) async {
    await _show(t);
    final antes = _script(t);
    await t.tap(find.text('Gerar outra senha'));
    await t.pump();
    expect(_script(t), isNot(antes));
  });

  testWidgets('liberar reinício e desfazer têm seus Copiar', (t) async {
    final copiado = await _show(t);
    await t.tap(find.byKey(const Key('copiar-reinicio')));
    await t.tap(find.byKey(const Key('copiar-desfazer')));
    await t.pump();
    expect(copiado, [scriptLiberarReinicio(ipOrigem: '10.9.9.9', ipsSede: ['203.0.113.5']), scriptDesfazer]);
  });

  testWidgets('sem as variáveis no servidor: avisa o que falta e não mostra o script', (t) async {
    await _show(t, info: {'ip_origem': '10.9.9.9', 'ips_publicos_sede': []});
    expect(find.textContaining('NODEBEAT_IPS_PUBLICOS_SEDE'), findsWidgets);
    expect(find.byKey(const Key('copiar-preparar')), findsNothing);
    expect(find.byKey(const Key('copiar-reinicio')), findsNothing); // precisa dos IPs da sede
  });

  testWidgets('liberar reinício pelo IP público tem seu Copiar', (t) async {
    final copiado = await _show(t);
    expect(find.text('MK já cadastrada: liberar o botão Reiniciar'), findsOneWidget);
    expect(find.textContaining('reinício pelo IP público'), findsNothing); // um cartão só
    expect(find.textContaining('Substitui os IPs permitidos na api-ssl'), findsOneWidget);
    await t.tap(find.byKey(const Key('copiar-reinicio')));
    await t.pump();
    expect(copiado, [scriptLiberarReinicio(ipOrigem: '10.9.9.9', ipsSede: ['203.0.113.5'])]);
  });

  testWidgets('test_liberar_publico_sem_ips_sede: avisa e não mostra o script', (t) async {
    await _show(t, info: {'ip_origem': '10.9.9.9', 'ips_publicos_sede': []});
    expect(find.text('Configure NODEBEAT_IPS_PUBLICOS_SEDE no servidor'), findsOneWidget);
    expect(find.byKey(const Key('copiar-reinicio')), findsNothing);
  });

  testWidgets('renderiza no tema escuro sem exceção', (t) async {
    await _show(t, b: Brightness.dark);
    expect(t.takeException(), isNull);
    expect(find.byKey(const Key('script-preparar')), findsOneWidget);
  });
}

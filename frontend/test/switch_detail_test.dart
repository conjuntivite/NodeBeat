import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/screens/switch_detail.dart';
import 'package:nodebeat/theme/theme.dart';

http.Response _json(Object o) =>
    http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _show(WidgetTester t, {String origem = 'manual'}) async {
  t.view.physicalSize = const Size(1400, 2000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final portas = {
    for (var i = 1; i <= 48; i++) '0/$i': {'up': i == 12, 'desde': '2026-01-01T10:00:00Z', 'caiu_em': null, 'velocidade': i == 12 ? 1000 : null},
    for (var i = 1; i <= 4; i++) 'sfp$i': {'up': false, 'desde': null, 'caiu_em': null, 'velocidade': null},
  };
  portas['0/5'] = {'up': true, 'desde': '2026-01-01T10:00:00Z', 'caiu_em': null, 'velocidade': 100};
  final mock = MockClient((req) async => switch (req.url.path) {
        '/api/equipamentos/s1' => _json({
            'id': 's1', 'tipo': 'switch', 'nome': 'sw-sede', 'ip': '10.0.0.9', 'local': 'sede', 'local_nome': 'Sede',
            'origem': origem, 'portas_total': 52, 'portas_up': 2,
            'estado': {'status': 'no_ar', 'detalhe': null, 'desde': '2026-01-01T10:00:00Z', 'portas': portas,
              'uplinks': {'0/12': {'filho': null, 'vigiados': 4}}},
            'uplinks': {'0/12': {'filho': null, 'vigiados': 4}},
          }),
        _ => _json([]),
      });
  await t.pumpWidget(MaterialApp(theme: tradeTheme(Brightness.light), home: SwitchDetailScreen(ApiClient(client: mock), 's1')));
  await t.pump();
  await t.pump();
}

void main() {
  testWidgets('desenha as 52 portas e mostra o cabeçalho', (t) async {
    await _show(t);
    expect(find.text('sw-sede'), findsWidgets);
    expect(find.textContaining('10.0.0.9'), findsOneWidget); // subtítulo: IP · local
    expect(find.byKey(const Key('porta-0/1')), findsOneWidget);
    expect(find.byKey(const Key('porta-sfp4')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('tocar na 0/12 mostra velocidade e "4 aparelhos vigiados"', (t) async {
    await _show(t);
    await t.tap(find.byKey(const Key('porta-0/12')));
    await t.pump();
    final det = find.byKey(const Key('detalhe-porta'));
    expect(find.descendant(of: det, matching: find.text('4 aparelhos vigiados')), findsOneWidget);
    expect(find.descendant(of: det, matching: find.text('1 Gbps')), findsOneWidget);
    await t.tap(find.byKey(const Key('porta-0/5')));
    await t.pump();
    expect(find.descendant(of: det, matching: find.text('100 Mbps')), findsOneWidget);
  });

  testWidgets('tabela lista todas as portas com a velocidade e marca a tocada', (t) async {
    await _show(t);
    final l12 = find.byKey(const Key('linha-porta-0/12'));
    expect(find.descendant(of: l12, matching: find.text('1 Gbps')), findsOneWidget);
    expect(find.descendant(of: l12, matching: find.text('4 aparelhos vigiados')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('linha-porta-0/5')), matching: find.text('100 Mbps')), findsOneWidget);
    await t.ensureVisible(l12);
    await t.pump();
    await t.tap(l12);
    await t.pump();
    final fundo = (t.widget<Container>(find.descendant(of: l12, matching: find.byType(Container)).first).decoration as BoxDecoration).color;
    expect(fundo, TradeTokens.light.brandTint); // linha selecionada em brand-tint
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('manual tem Apagar (com confirmação); descoberto não tem', (t) async {
    await _show(t);
    expect(find.text('Renomear'), findsOneWidget);
    await t.tap(find.text('Apagar'));
    await t.pump();
    expect(find.text('Apagar sw-sede?'), findsOneWidget);
    await t.tap(find.text('Cancelar'));
    await t.pump();
    await t.pumpWidget(const SizedBox());
    await _show(t, origem: 'descoberto');
    expect(find.text('Renomear'), findsOneWidget);
    expect(find.text('Apagar'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}

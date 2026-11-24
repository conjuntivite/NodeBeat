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

Map<String, dynamic> _unifi({int clientes30 = 30}) => {
      'lido_em': '2026-11-24T10:00:00Z',
      'sistema': {
        'modelo': 'USW-48-PoE', 'firmware': '7.6.11', 'atualizacao': true, 'uptime_s': 1000, 'cpu': 16, 'mem': 40,
        'temperatura': 53, 'poe_usado_w': 51.0, 'poe_max_w': 195, 'clientes': 31,
        'uplink': {'porta': 12, 'remoto': 'sw-core', 'remoto_porta': 3},
      },
      'portas': {
        '0/1': {
          'poe_w': 2.5, 'poe_classe': 'Class 2', 'rx_mbps': 10.0, 'tx_mbps': 0.4, 'erros': 0, 'descartes': 0, 'stp': 'forwarding',
          'quedas_link': 0, 'uplink': false, 'aparelhos': 1,
          'clientes': [{'nome': 'camera-01', 'ip': '192.0.2.10', 'mac': '02:00:00:00:00:01', 'fabricante': 'Acme', 'mbps': 1000.0}],
        },
        '0/2': {
          'poe_w': null, 'poe_classe': null, 'rx_mbps': null, 'tx_mbps': null, 'erros': null, 'descartes': null, 'stp': null,
          'quedas_link': null, 'uplink': false, 'aparelhos': clientes30,
          'clientes': [
            for (var i = 0; i < clientes30; i++)
              {'nome': i.isEven ? 'host-$i' : null, 'ip': '192.0.2.${i + 20}', 'mac': '02:00:00:00:01:${i.toRadixString(16).padLeft(2, '0')}', 'fabricante': null, 'mbps': null}
          ],
        },
        '0/3': {
          'poe_w': null, 'poe_classe': null, 'rx_mbps': null, 'tx_mbps': null, 'erros': null, 'descartes': null, 'stp': null,
          'quedas_link': null, 'uplink': false, 'aparelhos': 4,
          'clientes': [{'nome': 'pc-1', 'ip': null, 'mac': null, 'fabricante': null, 'mbps': null}],
        },
        '0/4': {
          'poe_w': null, 'poe_classe': null, 'rx_mbps': null, 'tx_mbps': null, 'erros': null, 'descartes': null, 'stp': null,
          'quedas_link': null, 'uplink': false, 'aparelhos': 3, 'clientes': [],
        },
        '0/12': {
          'poe_w': null, 'poe_classe': null, 'rx_mbps': 1.0, 'tx_mbps': 2.0, 'erros': 0, 'descartes': 0, 'stp': 'forwarding',
          'quedas_link': 0, 'uplink': true, 'aparelhos': 0, 'clientes': [],
        },
      },
    };

Future<void> _show(WidgetTester t,
    {String origem = 'manual', Map<String, dynamic>? unifi, double largura = 1400, Brightness brilho = Brightness.light}) async {
  t.view.physicalSize = Size(largura, 2000);
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
            'unifi': unifi,
          }),
        _ => _json([]),
      });
  await t.pumpWidget(MaterialApp(theme: tradeTheme(brilho), home: SwitchDetailScreen(ApiClient(client: mock), 's1')));
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

  testWidgets('indicadores do UniFi aparecem com unifi e somem sem ele', (t) async {
    await _show(t, unifi: _unifi());
    for (final x in ['CPU', 'Memória', 'Temperatura', 'PoE', 'Clientes']) {
      expect(find.text(x), findsWidgets, reason: x);
    }
    expect(find.text('Uptime'), findsOneWidget);
    expect(find.text('16 min'), findsOneWidget);
    expect(find.text('16%'), findsOneWidget);
    expect(find.text('53 °C'), findsOneWidget);
    expect(find.text('51,0 W'), findsOneWidget);
    expect(find.text('de 195 W'), findsOneWidget);
    expect(find.textContaining('Firmware 7.6.11 · atualização disponível'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await _show(t);
    expect(find.text('CPU'), findsNothing);
    expect(find.textContaining('Firmware'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('linha da 0/1 mostra PoE e tráfego; tocar mostra o cliente', (t) async {
    await _show(t, unifi: _unifi());
    final l = find.byKey(const Key('linha-porta-0/1'));
    expect(find.descendant(of: l, matching: find.text('2,5 W')), findsOneWidget);
    expect(find.descendant(of: l, matching: find.text('10,0 / 0,4 Mbps')), findsOneWidget);
    await t.ensureVisible(l);
    await t.pump();
    await t.tap(l);
    await t.pump();
    final det = find.byKey(const Key('detalhe-porta'));
    expect(find.descendant(of: det, matching: find.text('camera-01')), findsOneWidget);
    expect(find.descendant(of: det, matching: find.textContaining('192.0.2.10')), findsOneWidget);
    expect(find.descendant(of: det, matching: find.text('1 Gbps')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('coluna Clientes usa a lista quando existe, senão os aparelhos', (t) async {
    await _show(t, unifi: _unifi());
    expect(find.descendant(of: find.byKey(const Key('linha-porta-0/3')), matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('linha-porta-0/4')), matching: find.text('3')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('porta de uplink mostra para onde vai', (t) async {
    await _show(t, unifi: _unifi());
    await t.tap(find.byKey(const Key('porta-0/12')));
    await t.pump();
    expect(find.text('Uplink'), findsOneWidget);
    expect(find.text('para sw-core (porta 3)'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  for (final b in Brightness.values) {
    testWidgets('30 clientes em 360 px sem overflow (${b.name})', (t) async {
      await _show(t, unifi: _unifi(), largura: 360, brilho: b);
      final l = find.byKey(const Key('linha-porta-0/2'));
      await t.ensureVisible(l);
      await t.pump();
      await t.tapAt(t.getTopLeft(l) + const Offset(10, 10));
      await t.pump();
      expect(find.text('Equipamentos nesta porta (30)'), findsOneWidget);
      expect(find.text('Sem nome'), findsWidgets);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}

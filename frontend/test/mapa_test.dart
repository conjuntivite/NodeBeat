import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/mapa.dart';

http.Response _json(Object o, [int code = 200]) => http.Response(
  jsonEncode(o),
  code,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _ap(
  String ip,
  String estado, {
  String? nome,
  String? apelido,
  String? desde,
}) => {
  'ip': ip,
  'mac': 'AA:BB:CC:00:00:01',
  'fabricante': 'Intelbras',
  'nome': nome,
  'apelido': apelido,
  'vigiado': true,
  'e_switch': false,
  'estado': estado,
  'desde': desde,
  'ultimo_visto': null,
  'porta_desconhecida': false,
};

final _mapa = {
  'lido_em': '2026-01-01T10:00:00+00:00',
  'desatualizado': false,
  'mk_no_ar': true,
  'portas': [
    {
      'nome': 'ether3',
      'rotulo': 'Bloco A',
      'link': 'down',
      'vigiados': 2,
      'no_ar': 0,
      'problema': true,
      'causa': 'ether3 · link caído',
      'aparelhos': [
        _ap(
          '10.0.0.5',
          'offline',
          nome: 'camera1',
          desde: '2026-01-01T00:00:00+00:00',
        ),
        _ap('10.0.0.6', 'desconhecido', apelido: 'DVR'),
      ],
    },
    {
      'nome': 'ether4',
      'rotulo': null,
      'link': 'up',
      'vigiados': 1,
      'no_ar': 1,
      'problema': false,
      'causa': null,
      'aparelhos': [_ap('10.0.0.9', 'no_ar', nome: 'saudavel9')],
    },
  ],
};

Future<List<http.Request>> _show(
  WidgetTester t, {
  Brightness b = Brightness.light,
  Map<String, dynamic>? mapa,
  double largura = 400,
}) async {
  t.view.physicalSize = Size(largura, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final reqs = <http.Request>[];
  final api = ApiClient(
    client: MockClient((req) async {
      reqs.add(req);
      if (req.method == 'PUT') return http.Response('', 204);
      return req.url.path == '/api/mks/x/mapa'
          ? _json(mapa ?? _mapa)
          : http.Response('', 404);
    }),
  );
  await t.pumpWidget(
    MaterialApp(
      theme: tradeTheme(b),
      home: Scaffold(
        body: SingleChildScrollView(
          child: MapaRedeCard(api: api, id: 'x'),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  return reqs;
}

Map<String, dynamic> _porta(
  String nome,
  bool problema,
  List<Map<String, dynamic>> aps,
) => {
  'nome': nome,
  'rotulo': null,
  'link': 'up',
  'vigiados': aps.length,
  'no_ar': problema ? 0 : aps.length,
  'problema': problema,
  'causa': null,
  'aparelhos': aps,
};

Map<String, dynamic> _aninhado({Map<String, dynamic> extra = const {}}) => {
  'lido_em': '2026-01-01T10:00:00+00:00',
  'desatualizado': false,
  'mk_no_ar': true,
  'portas': [
    _porta('ether2', true, [
      {
        ..._ap('10.0.0.2', 'no_ar', nome: 'switch-sala'),
        'e_switch': true,
        'gerenciavel': true,
        'snmp_erro': false,
        'switch_lido_em': DateTime.now().toUtc().toIso8601String(),
        'portas': [
          _porta('7', true, [
            _ap(
              '10.0.0.7',
              'offline',
              nome: 'camera7',
              desde: '2026-01-01T00:00:00+00:00',
            ),
          ]),
          _porta('8', false, [_ap('10.0.0.8', 'no_ar', nome: 'saudavel8')]),
        ],
        ...extra,
      },
      {
        ..._ap('10.0.0.3', 'no_ar', nome: 'candidato'),
        'e_switch': true,
        'gerenciavel': false,
        'dica': 'gerenciável detectado: ative o SNMP nele',
      },
    ]),
  ],
};

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('switch gerenciável aninhado: selo, portas e dica ($b)', (
      t,
    ) async {
      await _show(t, b: b, mapa: _aninhado());
      expect(find.text('Gerenciável'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(
        find.text('10.0.0.7'),
        findsOneWidget,
      ); // porta com problema aberta
      expect(find.text('8'), findsOneWidget);
      expect(find.text('10.0.0.8'), findsNothing); // sadia recolhida
      await t.tap(find.text('8'));
      await t.pump();
      expect(find.text('10.0.0.8'), findsOneWidget);
      expect(
        find.text('gerenciável detectado: ative o SNMP nele'),
        findsOneWidget,
      );
      expect(find.textContaining('Sem resposta SNMP'), findsNothing);
      expect(find.textContaining('leitura do switch há'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('switch sem resposta SNMP mostra a hora da última leitura', (
    t,
  ) async {
    await _show(
      t,
      mapa: _aninhado(
        extra: {
          'snmp_erro': true,
          'switch_lido_em': '2026-01-01T10:00:00+00:00',
        },
      ),
    );
    final d = DateTime.parse('2026-01-01T10:00:00+00:00').toLocal();
    String dois(int n) => n.toString().padLeft(2, '0');
    expect(
      find.text(
        'Sem resposta SNMP; dados do switch de ${dois(d.hour)}:${dois(d.minute)} ${dois(d.day)}/${dois(d.month)}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('leitura do switch há'), findsNothing);
  });

  testWidgets('sem resposta SNMP e sem leitura', (t) async {
    await _show(
      t,
      mapa: _aninhado(extra: {'snmp_erro': true, 'switch_lido_em': null}),
    );
    expect(find.text('Sem resposta SNMP'), findsOneWidget);
  });

  testWidgets('leitura do switch antiga avisa há quanto tempo', (t) async {
    await _show(
      t,
      mapa: _aninhado(extra: {'switch_lido_em': '2026-01-01T10:00:00+00:00'}),
    );
    expect(find.textContaining('leitura do switch há'), findsOneWidget);
  });

  testWidgets('rotular só nas portas da MK, não nas de switch', (t) async {
    await _show(t, mapa: _aninhado());
    expect(
      find.text('rotular'),
      findsOneWidget,
    ); // ether2; as portas 7 e 8 do switch não têm
    expect(find.bySemanticsLabel('Editar rótulo da porta 7'), findsNothing);
  });

  testWidgets('aninhado em 400 px sem overflow', (t) async {
    await _show(t, mapa: _aninhado(extra: {'snmp_erro': true}), largura: 400);
    expect(t.takeException(), isNull);
  });

  testWidgets('mudar só "É um switch" envia só e_switch', (t) async {
    final reqs = await _show(t);
    await t.tap(find.text('10.0.0.5'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(SwitchListTile, 'É um switch'));
    await t.pump();
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    final put = reqs.firstWhere((r) => r.method == 'PUT');
    expect(jsonDecode(put.body), {'e_switch': true});
  });

  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('porta com problema aberta, estados e sadia recolhida ($b)', (
      t,
    ) async {
      await _show(t, b: b);
      expect(find.textContaining('link caído'), findsWidgets);
      expect(find.text('ether3 · link caído'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.text('Sem informação'), findsOneWidget);
      expect(find.textContaining('visto no ar há'), findsOneWidget);
      expect(find.text('10.0.0.9'), findsNothing); // ether4 sadia: recolhida
      expect(find.text('1/1 no ar'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.text('ether4'));
      await t.pump();
      expect(find.text('10.0.0.9'), findsOneWidget);
      expect(find.text('No ar'), findsOneWidget);
    });
  }

  testWidgets('busca chama o endpoint com q=', (t) async {
    final reqs = await _show(t);
    await t.enterText(find.byType(TextField), 'cam');
    await t.pump(const Duration(milliseconds: 500));
    await t.pump();
    expect(reqs.last.url.query, 'q=cam');
  });

  testWidgets('só com problema manda so_problema=true', (t) async {
    final reqs = await _show(t);
    await t.tap(find.byType(Switch));
    await t.pump();
    expect(reqs.last.url.query, 'so_problema=true');
  });

  testWidgets('editar apelido envia PUT com o corpo certo', (t) async {
    final reqs = await _show(t);
    await t.tap(find.text('10.0.0.5'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Câmera pátio');
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    final put = reqs.firstWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/mks/x/mapa/aparelhos/10.0.0.5');
    expect(jsonDecode(put.body), {'apelido': 'Câmera pátio'});
  });

  testWidgets('mudar só a chave vigiar envia só vigiar', (t) async {
    final reqs = await _show(t);
    await t.tap(find.text('10.0.0.5'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(SwitchListTile, 'Vigiar este aparelho'));
    await t.pump();
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    final put = reqs.firstWhere((r) => r.method == 'PUT');
    expect(jsonDecode(put.body), {'vigiar': false});
  });

  testWidgets('rótulo da porta envia PUT', (t) async {
    final reqs = await _show(t);
    await t.tap(find.text('Bloco A'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Bloco B');
    await t.tap(find.text('Salvar'));
    await t.pumpAndSettle();
    final put = reqs.firstWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/mks/x/mapa/rotulo-porta');
    expect(jsonDecode(put.body), {'porta': 'ether3', 'rotulo': 'Bloco B'});
  });

  testWidgets('avisos de MK fora do ar e desatualizado', (t) async {
    await _show(
      t,
      mapa: {
        'lido_em': null,
        'desatualizado': true,
        'mk_no_ar': false,
        'portas': [],
      },
    );
    expect(
      find.text('MK fora do ar: estado dos aparelhos desconhecido'),
      findsOneWidget,
    );
    expect(find.text('leitura desatualizada'), findsOneWidget);
    expect(find.text('Nenhum aparelho mapeado.'), findsOneWidget);
  });

  testWidgets('JSON vazio não quebra', (t) async {
    await _show(t, mapa: {});
    expect(t.takeException(), isNull);
    expect(find.text('Nenhum aparelho mapeado.'), findsOneWidget);
  });
}

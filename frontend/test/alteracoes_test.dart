import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/alteracoes.dart';

http.Response _json(Object o, [int code = 200]) =>
    http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json; charset=utf-8'});

const _semRw = "Para alterar esta MK pelo NodeBeat, aplique o script 'permitir alterações' da página Preparar MK e preencha a senha no cadastro.";
const _peers = {
  'via': 'publico',
  'peers': [
    {'id': '*1', 'nome': 'sede', 'endereco': '203.0.113.5', 'desativado': false, 'comentario': null, 'por_dominio': false},
    {'id': '*2', 'nome': 'lb', 'endereco': 'vpn.exemplo.test', 'desativado': false, 'comentario': null, 'por_dominio': true},
  ],
};
const _lib = {
  'via': 'tunel',
  'liberacoes': [
    {'descricao': 'camera', 'protocolos': ['tcp'], 'porta_externa': 8080, 'ip_interno': '192.168.88.10',
      'porta_interna': 80, 'wan': 'ether1', 'desativada': false},
  ],
};

Future<void> _mostra(WidgetTester t, Widget Function(ApiClient) w, Brightness b, MockClientHandler h) async {
  t.view.physicalSize = const Size(1200, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: tradeTheme(b), home: Scaffold(body: SingleChildScrollView(child: w(ApiClient(client: MockClient(h)))))));
  await t.pumpAndSettle();
}

Future<void> _toque(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    group('$b', () {
      testWidgets('sem temRw: aviso e botões desabilitados', (t) async {
        await _mostra(t, (a) => Column(children: [
              IpsecCard(api: a, id: 'x', temRw: false, ipsSede: const []),
              PortasLiberadasCard(api: a, id: 'x', temRw: false),
            ]), b, (r) async => _json({}));
        expect(find.text(_semRw), findsNWidgets(2));
        expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Carregar peers')).onPressed, isNull);
        expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Carregar portas')).onPressed, isNull);
        expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Liberar porta')).onPressed, isNull);
      });

      testWidgets('IPsec: lista, troca o peer e mostra o caminho', (t) async {
        final puts = <http.Request>[];
        await _mostra(t, (a) => IpsecCard(api: a, id: 'x', temRw: true, ipsSede: const ['198.51.100.7']), b, (r) async {
          if (r.method == 'PUT') {
            puts.add(r);
            return _json({'antigo': '203.0.113.5', 'novo': '198.51.100.7', 'confirmado': true, 'policies_erro': [], 'via': 'publico'});
          }
          return _json(_peers);
        });
        await _toque(t, find.text('Carregar peers'));
        expect(find.text('pelo domínio: sobe sozinho pelo load balance'), findsOneWidget);
        expect(find.text('Trocar peer'), findsNWidgets(2));
        for (final bt in find.widgetWithText(OutlinedButton, 'Trocar peer').evaluate()) {
          expect((bt.widget as OutlinedButton).onPressed, isNotNull);
        }
        await _toque(t, find.text('Trocar peer').last);
        expect(find.textContaining('trocar para IP fixo tira isso'), findsOneWidget);
        await _toque(t, find.text('Cancelar'));
        await _toque(t, find.text('Trocar peer').first);
        expect(find.textContaining('trocar para IP fixo tira isso'), findsNothing);
        await _toque(t, find.widgetWithText(ActionChip, '198.51.100.7'));
        expect(find.text('Atual: 203.0.113.5 → Novo: 198.51.100.7'), findsOneWidget);
        await _toque(t, find.widgetWithText(FilledButton, 'Trocar'));
        expect(jsonDecode(puts.single.body), {'endereco': '198.51.100.7'});
        expect(puts.single.url.path, '/api/mks/x/ipsec/peers/*1');
        expect(find.textContaining('pelo IP público'), findsOneWidget);
      });

      testWidgets('IPsec: não confirmado e policy com erro', (t) async {
        await _mostra(t, (a) => IpsecCard(api: a, id: 'x', temRw: true, ipsSede: const []), b, (r) async {
          if (r.method == 'PUT') {
            return _json({'antigo': 'a', 'novo': 'b', 'confirmado': false, 'policies_erro': ['*9'], 'via': 'tunel'});
          }
          return _json(_peers);
        });
        await _toque(t, find.text('Carregar peers'));
        await _toque(t, find.text('Trocar peer').first);
        await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '198.51.100.8');
        await t.pump();
        await _toque(t, find.widgetWithText(FilledButton, 'Trocar'));
        expect(find.textContaining('Enviado; não deu para confirmar'), findsOneWidget);
        expect(find.textContaining('policy *9 não foi atualizada'), findsOneWidget);
      });

      testWidgets('Portas: libera, mostra WAN e avisos; 422 mostra o detalhe', (t) async {
        final posts = <http.Request>[];
        var falha = false;
        await _mostra(t, (a) => PortasLiberadasCard(api: a, id: 'x', temRw: true), b, (r) async {
          if (r.url.path.endsWith('/ips')) {
            return _json([{'ip': '192.168.88.20', 'mac': null, 'host_name': null, 'fixo': false, 'ultimo_visto': null, 'em_uso': true}]);
          }
          if (r.method == 'POST') {
            posts.add(r);
            return falha
                ? _json({'detail': 'Porta 8291 reservada'}, 422)
                : _json({'wan': 'ether1', 'via': 'tunel', 'avisos': ['cuidado']});
          }
          return _json(_lib);
        });
        await _toque(t, find.text('Carregar portas'));
        expect(find.text('camera'), findsOneWidget);
        await _toque(t, find.text('Liberar porta'));
        final campos = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
        await t.enterText(campos.at(0), '8081');
        await _toque(t, find.widgetWithText(ActionChip, '192.168.88.20'));
        await t.enterText(campos.at(3), 'impressora');
        await t.pump();
        await _toque(t, find.widgetWithText(FilledButton, 'Liberar'));
        expect(jsonDecode(posts.single.body), {
          'protocolo': 'tcp', 'porta_externa': 8081, 'ip_interno': '192.168.88.20', 'porta_interna': 8081, 'descricao': 'impressora',
        });
        expect(find.textContaining('ether1'), findsWidgets);
        expect(find.textContaining('cuidado'), findsOneWidget);
        expect(find.textContaining('pelo túnel'), findsOneWidget);

        falha = true;
        await _toque(t, find.text('Liberar porta'));
        await t.enterText(campos.at(0), '8291');
        await t.enterText(campos.at(1), '192.168.88.20');
        await t.enterText(campos.at(3), 'x');
        await t.pump();
        await _toque(t, find.widgetWithText(FilledButton, 'Liberar'));
        expect(find.text('Porta 8291 reservada'), findsOneWidget);
      });

      testWidgets('Portas: remover pede confirmação e faz DELETE com a descrição', (t) async {
        final dels = <http.Request>[];
        await _mostra(t, (a) => PortasLiberadasCard(api: a, id: 'x', temRw: true), b, (r) async {
          if (r.method == 'DELETE') {
            dels.add(r);
            return _json({});
          }
          return _json(_lib);
        });
        await _toque(t, find.text('Carregar portas'));
        await _toque(t, find.widgetWithText(TextButton, 'Remover'));
        expect(dels, isEmpty);
        await _toque(t, find.widgetWithText(FilledButton, 'Remover'));
        expect(dels.single.url.queryParameters['descricao'], 'camera');
      });
    });
  }
}

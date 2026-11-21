import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/audio/monitor_sound.dart';
import 'package:nodebeat/screens/dashboard.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/common.dart';

Map<String, dynamic> _mk(String id, String nome, String status, [List<String> alertas = const []]) => {
      'id': id, 'nome': nome, 'status': status, 'desde': '2026-01-01T10:00:00-03:00', 'cpu': 12.0, 'mem': 40,
      'uptime': '1d2h', 'ifaces_ok': 2, 'ifaces_total': 3, 'alertas': alertas, 'versao': '7.14',
    };

class _FakeEngine extends SoundEngine {
  _FakeEngine({this.on = true});
  final bool on;
  bool suspended = true;
  int unlocks = 0;
  late bool bip = on, queda = on;
  @override
  bool get savedBip => bip;
  @override
  set savedBip(bool v) => bip = v;
  @override
  bool get savedQueda => queda;
  @override
  set savedQueda(bool v) => queda = v;
  @override
  bool get isSuspended => suspended;
  @override
  void unlock() {
    unlocks++;
    suspended = false;
  }

  int beeps = 0;
  bool flat = false;
  @override
  void beep() => beeps++;
  @override
  void startFlatline() => flat = true;
  @override
  void stop() => flat = false;
}

Future<void> _show(WidgetTester t, Map<String, dynamic> body, {int status = 200, SoundEngine? sound, String? abrir}) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = ApiClient(client: MockClient((req) async => http.Response(jsonEncode(body), status)));
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(Brightness.light),
    onGenerateRoute: (s) => MaterialPageRoute(
        settings: s,
        builder: (_) => s.name == '/login'
            ? const Text('LOGIN')
            : s.name == '/preparar-mk'
            ? const Text('PREPARAR')
            : s.name == '/eventos'
            ? const Text('EVENTOS')
            : s.name!.startsWith('/mk/')
                ? Text('DETALHE ${s.name}')
                : DashboardScreen(api: api, sound: sound, abrir: abrir)),
  ));
  await t.pump();
  await t.pump();
}

Map<String, dynamic> _status({int fila = 0, bool sede = true, bool dados = true}) => {
      'resumo': {'no_ar': 1, 'com_alerta': 1, 'fora': 1},
      'fila_pendente': fila,
      'sede_ok': sede,
      'dados_ok': dados,
      'mks': [
        _mk('a', 'cliente-v7', 'vpn_caiu'),
        _mk('b', 'cliente-b', 'no_ar', ['CPU alta (92%)']),
        _mk('c', 'cliente-c', 'no_ar'),
      ],
    };

Finder _rows() => find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('row-'));

void main() {
  testWidgets('cards 1/1/1, primeira linha é a que está fora, banner da fila', (t) async {
    await _show(t, _status(fila: 3));
    for (final k in ['resumo-no_ar', 'resumo-alerta', 'resumo-fora']) {
      expect(find.descendant(of: find.byKey(Key(k)), matching: find.text('1')), findsOneWidget, reason: k);
    }
    expect(find.descendant(of: _rows().first, matching: find.text('cliente-v7')), findsOneWidget);
    expect(find.text('3 eventos aguardando envio'), findsOneWidget);
    expect(find.text('Sem conexão da sede — dados congelados'), findsNothing);
    expect(find.text('2/3'), findsNWidgets(3));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('ícone "Preparar MK" abre a página do script', (t) async {
    await _show(t, _status());
    await t.tap(find.byTooltip('Preparar MK'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('PREPARAR'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('ícone "Eventos" abre a aba de eventos', (t) async {
    await _show(t, _status());
    await t.tap(find.byTooltip('Eventos'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('EVENTOS'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('sem sede → aviso; sem fila → sem banner de fila', (t) async {
    await _show(t, _status(sede: false));
    expect(find.text('Sem conexão da sede — dados congelados'), findsOneWidget);
    expect(find.textContaining('aguardando envio'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('worker parado → aviso de dados desatualizados', (t) async {
    await _show(t, _status());
    expect(find.text('Monitor parado — dados desatualizados'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await _show(t, _status(dados: false));
    expect(find.text('Monitor parado — dados desatualizados'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('clicar no cabeçalho ordena por condomínio', (t) async {
    await _show(t, _status());
    await t.tap(find.text('Condomínio'));
    await t.pump();
    expect(find.descendant(of: _rows().first, matching: find.text('cliente-b')), findsOneWidget);
    await t.tap(find.text('Condomínio'));
    await t.pump();
    expect(find.descendant(of: _rows().first, matching: find.text('cliente-v7')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('401 volta ao login', (t) async {
    await _show(t, {'detail': 'x'}, status: 401);
    expect(find.text('LOGIN'), findsOneWidget);
  });

  testWidgets('som salvo como ligado mas suspenso: aviso e destrava no primeiro clique', (t) async {
    final e = _FakeEngine();
    await _show(t, _status(), sound: e);
    expect(find.text('Clique para ativar o som'), findsOneWidget);
    await t.tap(find.text('Condomínio'));
    await t.pump(const Duration(milliseconds: 200));
    expect(e.unlocks, 1);
    expect(find.text('Clique para ativar o som'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('som desligado: sem aviso', (t) async {
    await _show(t, _status(), sound: _FakeEngine(on: false));
    expect(find.text('Clique para ativar o som'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('fila com 1 evento usa o singular', (t) async {
    await _show(t, _status(fila: 1));
    expect(find.text('1 evento aguardando envio'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('ordenação é estável: empate mantém a ordem do servidor', (t) async {
    await _show(t, _status());
    await t.tap(find.text('CPU')); // as três MKs têm a mesma CPU
    await t.pump();
    expect(find.descendant(of: _rows().first, matching: find.text('cliente-v7')), findsOneWidget);
    await t.tap(find.text('CPU'));
    await t.pump();
    expect(find.descendant(of: _rows().first, matching: find.text('cliente-v7')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('cabeçalho ordenável tem semântica de botão com estado', (t) async {
    final h = t.ensureSemantics();
    await _show(t, _status());
    expect(find.bySemanticsLabel('Ordenar por Condomínio'), findsOneWidget);
    await t.tap(find.text('Condomínio'));
    await t.pump();
    expect(find.bySemanticsLabel('Ordenar por Condomínio, crescente'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    h.dispose();
  });

  testWidgets('painel não tem seta de voltar mesmo com rota por baixo', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = ApiClient(client: MockClient((req) async => http.Response(jsonEncode(_status()), 200)));
    await t.pumpWidget(MaterialApp(
      theme: tradeTheme(Brightness.light),
      home: Builder(
          builder: (c) => TextButton(onPressed: () => Navigator.of(c).pushNamed('/painel'), child: const Text('IR'))),
      onGenerateRoute: (s) => MaterialPageRoute(settings: s, builder: (_) => DashboardScreen(api: api)),
    ));
    await t.tap(find.text('IR'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  test('formatDateTime e formatDuration', () {
    expect(formatDateTime(null), '');
    expect(formatDateTime(DateTime(2026, 1, 2, 9, 5).toIso8601String()), '02/01/2026 09:05');
    expect(formatDuration(45), '45 s');
    expect(formatDuration(3900), '1 h 5 min');
    expect(formatDuration(180000), '2 d 2 h');
  });

  test('relativo', () {
    final now = DateTime.utc(2026, 1, 2, 12);
    expect(relativo('2026-01-02T11:59:40Z', now: now), '<1 min');
    expect(relativo('2026-01-02T11:54:00Z', now: now), '6 min');
    expect(relativo('2026-01-02T09:00:00Z', now: now), '3 h');
    expect(relativo('2025-12-30T12:00:00Z', now: now), '3 d');
  });
  testWidgets('dentro da MK o som foca nela; ao voltar, volta ao painel todo', (t) async {
    final e = _FakeEngine()..suspended = false;
    await _show(t, _status(), sound: e);
    expect(e.flat, isTrue); // cliente-v7 fora: apito no painel
    await t.tap(find.byKey(const ValueKey('row-c')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('DETALHE /mk/c'), findsOneWidget);
    expect(e.flat, isFalse); // cliente-c no ar: sem apito
    final antes = e.beeps;
    await t.pump(const Duration(milliseconds: 2500));
    expect(e.beeps, greaterThan(antes)); // segue o bip da MK focada
    Navigator.of(t.element(find.text('DETALHE /mk/c'))).pop();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(e.flat, isTrue);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('MK focada fora: apito contínuo', (t) async {
    final e = _FakeEngine()..suspended = false;
    final body = _status()..['mks'] = [_mk('a', 'cliente-v7', 'vpn_caiu'), _mk('c', 'cliente-c', 'no_ar')];
    await _show(t, body, sound: e);
    await t.tap(find.byKey(const ValueKey('row-a')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(e.flat, isTrue);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('menu do som: desligar "perda" para o apito e salva a escolha', (t) async {
    final e = _FakeEngine()..suspended = false;
    await _show(t, _status(), sound: e);
    expect(e.flat, isTrue);
    await t.tap(find.byTooltip('Som'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Som de batimento'), findsOneWidget);
    await t.tap(find.text('Som de perda'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(e.flat, isFalse);
    expect(e.queda, isFalse);
    expect(e.bip, isTrue);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('menu do som: desligar "batimento" para o bip', (t) async {
    final e = _FakeEngine()..suspended = false;
    final body = _status()..['mks'] = [_mk('c', 'cliente-c', 'no_ar')];
    await _show(t, body, sound: e);
    await t.tap(find.byTooltip('Som'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('Som de batimento'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    final antes = e.beeps;
    await t.pump(const Duration(milliseconds: 2500));
    expect(e.beeps, antes);
    expect(e.bip, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('recarregar dentro da MK: painel por baixo, som focado nela e voltar cai no painel', (t) async {
    final e = _FakeEngine()..suspended = false;
    final body = _status()..['mks'] = [_mk('a', 'cliente-v7', 'vpn_caiu'), _mk('c', 'cliente-c', 'no_ar')];
    await _show(t, body, sound: e, abrir: 'a');
    await t.pump(const Duration(seconds: 1));
    expect(find.text('DETALHE /mk/a'), findsOneWidget);
    expect(e.flat, isTrue);
    Navigator.of(t.element(find.text('DETALHE /mk/a'))).pop();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('row-c')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/widgets/heartbeat.dart';

Future<HeartbeatPainter> _paint(WidgetTester t, String status,
    {bool alert = false, Brightness b = Brightness.light, bool reduced = false}) async {
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(b),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: HeartbeatLine(status: status, alert: alert),
    ),
  ));
  final cp = t.widget<CustomPaint>(find.descendant(of: find.byType(HeartbeatLine), matching: find.byType(CustomPaint)));
  return cp.painter as HeartbeatPainter;
}

void main() {
  testWidgets('offline → reta em negative', (t) async {
    final p = await _paint(t, 'offline');
    expect(p.isFlat, true);
    expect(p.color, TradeTokens.light.negative);
  });

  testWidgets('no_ar → traçado em positive; escuro usa o token escuro', (t) async {
    var p = await _paint(t, 'no_ar');
    expect(p.isFlat, false);
    expect(p.color, TradeTokens.light.positive);
    await t.pumpWidget(const SizedBox());
    p = await _paint(t, 'no_ar', b: Brightness.dark);
    expect(p.color, TradeTokens.dark.positive);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('no_ar com alerta → warning', (t) async {
    final p = await _paint(t, 'no_ar', alert: true);
    expect(p.isFlat, false);
    expect(p.color, TradeTokens.light.warning);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('aguardando → traçado parado em fgMuted', (t) async {
    final p = await _paint(t, 'aguardando');
    expect(p.isFlat, false);
    expect(p.color, TradeTokens.light.fgMuted);
    expect(p.progress, 0);
  });

  testWidgets('movimento reduzido: traçado parado, forma mantida', (t) async {
    final p = await _paint(t, 'no_ar', reduced: true);
    await t.pump(const Duration(milliseconds: 500));
    expect(p.isFlat, false);
    expect(p.progress, 0);
  });
}

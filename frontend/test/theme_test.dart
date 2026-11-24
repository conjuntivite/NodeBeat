import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';

double _lin(double c) => c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
double _lum(Color c) => 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);
double contrast(Color a, Color b) {
  final l1 = _lum(a), l2 = _lum(b);
  return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05);
}

void main() {
  test('fundo do scaffold vem do token bgPage', () {
    expect(tradeTheme(Brightness.light).scaffoldBackgroundColor, TradeTokens.light.bgPage);
    expect(tradeTheme(Brightness.dark).scaffoldBackgroundColor, TradeTokens.dark.bgPage);
  });

  test('fgPrimary sobre bgSurface tem contraste >= 4,5 nos dois temas', () {
    for (final t in [TradeTokens.light, TradeTokens.dark]) {
      expect(contrast(t.fgPrimary, t.bgSurface), greaterThanOrEqualTo(4.5));
    }
  });

  test('botão secundário (outlined): brandText sobre bgSurface >= 4,5 e borda borderStrong', () {
    for (final b in [Brightness.light, Brightness.dark]) {
      final t = b == Brightness.light ? TradeTokens.light : TradeTokens.dark;
      final st = tradeTheme(b).outlinedButtonTheme.style!;
      final fg = st.foregroundColor!.resolve({})!, bg = st.backgroundColor!.resolve({})!;
      expect(fg, t.brandText);
      expect(bg, t.bgSurface);
      expect(st.side!.resolve({})!.color, t.borderStrong);
      expect(contrast(fg, bg), greaterThanOrEqualTo(4.5));
    }
  });

  test('marca pink do NodeBeat: #FF4FA3 no escuro, tom fechado no claro; textos >= 4,5', () {
    expect(TradeTokens.dark.actionPrimary, const Color(0xFFFF4FA3));
    expect(TradeTokens.light.actionPrimary, const Color(0xFFCE2274));
    for (final t in [TradeTokens.light, TradeTokens.dark]) {
      expect(t.bgBrand, t.actionPrimary);
      expect(contrast(t.actionPrimaryFg, t.actionPrimary), greaterThanOrEqualTo(4.5));
      expect(contrast(t.actionPrimaryFg, t.brandHover), greaterThanOrEqualTo(4.5));
      expect(contrast(t.brandText, t.bgSurface), greaterThanOrEqualTo(4.5));
      expect(contrast(t.brandText, t.brandTint), greaterThanOrEqualTo(4.5));
      expect(contrast(t.fgSecondary, t.bgSubtle), greaterThanOrEqualTo(4.5));
      expect(contrast(t.fgSecondary, t.bgHover), greaterThanOrEqualTo(4.5));
      expect(contrast(t.fgInverse, t.negative), greaterThanOrEqualTo(4.5)); // contador da barra lateral
      expect(contrast(t.borderStrong, t.bgSurface), greaterThanOrEqualTo(3));
    }
  });
}

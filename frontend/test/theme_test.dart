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
}

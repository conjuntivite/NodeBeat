import 'package:material_ui/material_ui.dart';

import 'tokens.g.dart';

/// Tema escolhido pelo usuário; o app raiz escuta e a barra/login alternam.
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

TradeTokens tokensOf(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? TradeTokens.dark : TradeTokens.light;

/// Valores numéricos: Space Mono com algarismos tabulares.
TextStyle dataStyle(BuildContext c, [TextStyle base = TradeType.dataMd]) => base.copyWith(
      fontFamily: TradeType.monoFamily,
      color: tokensOf(c).fgPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

ThemeData tradeTheme(Brightness b) {
  final t = b == Brightness.dark ? TradeTokens.dark : TradeTokens.light;
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radiusPill));
  OutlineInputBorder border(Color color, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(t.radiusMd), borderSide: BorderSide(color: color, width: w));
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    fontFamily: TradeType.sansFamily,
    scaffoldBackgroundColor: t.bgPage,
    colorScheme: ColorScheme(
      brightness: b,
      primary: t.actionPrimary,
      onPrimary: t.actionPrimaryFg,
      secondary: t.actionAccent,
      onSecondary: t.fgOnBrand,
      error: t.negative,
      onError: t.fgInverse,
      surface: t.bgSurface,
      onSurface: t.fgPrimary,
      outline: t.borderStrong,
      outlineVariant: t.borderSubtle,
    ),
    textTheme: TextTheme(
      headlineSmall: TradeType.heading2,
      titleMedium: TradeType.heading4,
      bodyLarge: TradeType.bodyLg,
      bodyMedium: TradeType.bodyMd,
      bodySmall: TradeType.bodySm,
      labelLarge: TradeType.label,
    ).apply(bodyColor: t.fgPrimary, displayColor: t.fgPrimary),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.actionPrimary,
        foregroundColor: t.actionPrimaryFg,
        disabledBackgroundColor: t.borderSubtle,
        disabledForegroundColor: t.fgMuted,
        shape: pill,
        textStyle: TradeType.label,
        padding: EdgeInsets.symmetric(horizontal: t.space4, vertical: t.space3),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: t.bgElevated,
        foregroundColor: t.fgPrimary,
        side: BorderSide(color: t.borderStrong),
        disabledForegroundColor: t.fgMuted,
        shape: pill,
        textStyle: TradeType.label,
        padding: EdgeInsets.symmetric(horizontal: t.space4, vertical: t.space3),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: t.fgPrimary, backgroundColor: t.bgElevated, shape: pill),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.bgElevated,
      labelStyle: TradeType.label.copyWith(color: t.fgSecondary),
      floatingLabelStyle: TradeType.label.copyWith(color: t.fgPrimary),
      errorStyle: TradeType.bodySm.copyWith(color: t.negative),
      border: border(t.borderStrong),
      enabledBorder: border(t.borderStrong),
      focusedBorder: border(t.fgPrimary, 2),
      errorBorder: border(t.negative),
      focusedErrorBorder: border(t.negative, 2),
    ),
  );
}

/// Alterna claro/escuro. O `Theme` ativo decide o próximo valor.
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: dark ? 'Tema claro' : 'Tema escuro',
      icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20),
      onPressed: () => themeMode.value = dark ? ThemeMode.light : ThemeMode.dark,
    );
  }
}

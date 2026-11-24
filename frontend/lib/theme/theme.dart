import 'package:material_ui/material_ui.dart';

import 'tokens.g.dart';

/// Tema escolhido pelo usuário; o app raiz escuta e a barra/login alternam.
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

TradeTokens tokensOf(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? TradeTokens.dark : TradeTokens.light;

/// Valores numéricos: Poppins com algarismos tabulares (IP/MAC/ID usam [TradeType.ticker], mono).
TextStyle dataStyle(BuildContext c, [TextStyle base = TradeType.dataMd]) => base.copyWith(
      color: tokensOf(c).fgPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

ThemeData tradeTheme(Brightness b) {
  final t = b == Brightness.dark ? TradeTokens.dark : TradeTokens.light;
  final md = RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radiusMd));
  final pad = EdgeInsets.symmetric(horizontal: t.space4, vertical: 9);
  OutlineInputBorder border(Color color, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(t.radiusMd), borderSide: BorderSide(color: color, width: w));
  WidgetStateProperty<Color?> overlay(Color hover) => WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed) ? hover : null);
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    fontFamily: TradeType.sansFamily,
    scaffoldBackgroundColor: t.bgPage,
    splashFactory: NoSplash.splashFactory, // sem animação decorativa: só a troca de cor (150 ms)
    hoverColor: t.bgHover,
    focusColor: t.brandTint,
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
      surfaceContainerHighest: t.bgSubtle,
      outline: t.borderStrong,
      outlineVariant: t.borderSubtle,
    ),
    textTheme: TextTheme(
      headlineSmall: TradeType.heading2,
      titleLarge: TradeType.heading3,
      titleMedium: TradeType.heading4,
      bodyLarge: TradeType.bodyLg,
      bodyMedium: TradeType.bodyMd,
      bodySmall: TradeType.bodySm,
      labelLarge: TradeType.button,
    ).apply(bodyColor: t.fgPrimary, displayColor: t.fgPrimary),
    appBarTheme: AppBarTheme(
      backgroundColor: t.bgSurface,
      foregroundColor: t.fgPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TradeType.heading3.copyWith(color: t.fgPrimary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? t.bgHover
            : s.contains(WidgetState.pressed)
                ? t.bgBrandDeep
                : s.contains(WidgetState.hovered)
                    ? t.brandHover
                    : t.actionPrimary),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? t.fgDisabled : t.actionPrimaryFg),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(md),
        textStyle: const WidgetStatePropertyAll(TradeType.button),
        padding: WidgetStatePropertyAll(pad),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: t.bgSurface,
        foregroundColor: t.brandText,
        side: BorderSide(color: t.borderStrong),
        disabledForegroundColor: t.fgDisabled,
        shape: md,
        textStyle: TradeType.button,
        padding: pad,
      ).copyWith(overlayColor: overlay(t.brandTint)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.brandText,
        disabledForegroundColor: t.fgDisabled,
        shape: md,
        textStyle: TradeType.button,
        padding: pad,
      ).copyWith(overlayColor: overlay(t.brandTint)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: t.fgSecondary, shape: md)
          .copyWith(overlayColor: overlay(t.bgHover)),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: t.actionPrimary,
      foregroundColor: t.actionPrimaryFg,
      elevation: 0,
      hoverElevation: 0,
      shape: md,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.bgSurface,
      hoverColor: Colors.transparent,
      contentPadding: EdgeInsets.symmetric(horizontal: t.space3, vertical: t.space3),
      labelStyle: TradeType.label.copyWith(color: t.fgSecondary),
      floatingLabelStyle: TradeType.label.copyWith(color: t.fgPrimary),
      hintStyle: TradeType.bodyLg.copyWith(color: t.fgSecondary),
      helperStyle: TradeType.bodySm.copyWith(color: t.fgSecondary),
      errorStyle: TradeType.bodySm.copyWith(color: t.negative),
      border: border(t.borderStrong),
      enabledBorder: border(t.borderStrong),
      focusedBorder: border(t.focusRing, 2),
      errorBorder: border(t.negative),
      focusedErrorBorder: border(t.negative, 2),
      disabledBorder: border(t.borderSubtle),
    ),
    cardTheme: CardThemeData(
      color: t.bgSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusLg), side: BorderSide(color: t.borderSubtle)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.bgSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusLg), side: BorderSide(color: t.borderSubtle)),
      titleTextStyle: TradeType.heading3.copyWith(color: t.fgPrimary),
      contentTextStyle: TradeType.bodyLg.copyWith(color: t.fgPrimary),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.bgSurface,
      surfaceTintColor: Colors.transparent,
      textStyle: TradeType.bodyMd.copyWith(color: t.fgPrimary),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusMd), side: BorderSide(color: t.borderSubtle)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.bgSurface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radiusMd), side: BorderSide(color: t.borderSubtle))),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: t.bgInverse, borderRadius: BorderRadius.circular(t.radiusSm)),
      textStyle: TradeType.bodySm.copyWith(color: t.fgInverse),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    dividerTheme: DividerThemeData(color: t.borderSubtle, space: 1, thickness: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.actionPrimary, linearTrackColor: t.brandTint),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.actionPrimaryFg : t.borderStrong),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.actionPrimary : t.bgSurface),
      trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.actionPrimary : t.borderStrong),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.actionPrimary : t.bgSurface),
      checkColor: WidgetStatePropertyAll(t.actionPrimaryFg),
      side: BorderSide(color: t.borderStrong),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.actionPrimary : t.borderStrong),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.bgInverse,
      contentTextStyle: TradeType.bodyMd.copyWith(color: t.fgInverse),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radiusMd)),
      behavior: SnackBarBehavior.floating,
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

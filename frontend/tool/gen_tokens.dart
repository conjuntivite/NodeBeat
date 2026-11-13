// Gera lib/theme/tokens.g.dart a partir de design-system/tokens.json.
// Uso: dart run tool/gen_tokens.dart
import 'dart:convert';
import 'dart:io';

String camel(String n) {
  final p = n.split('-');
  return p.first + p.skip(1).map((s) => s[0].toUpperCase() + s.substring(1)).join();
}

String hex(String v) => '0xFF${v.substring(1).toUpperCase()}';

void main() {
  final j = jsonDecode(File('design-system/tokens.json').readAsStringSync()) as Map<String, dynamic>;
  final prim = <String, String>{};
  final sem = <String, Map<String, String>>{};
  for (final t in (j['color']['tokens'] as List).cast<Map<String, dynamic>>()) {
    final v = t['value'];
    if (v is String) {
      prim[t['name']] = v;
    } else {
      sem[t['name']] = (v as Map).cast<String, String>();
    }
  }
  String resolve(String v) => v.startsWith('{') ? prim[v.substring(1, v.length - 1)]! : v;
  num px(String v) => num.parse(v.replaceAll('px', ''));

  final b = StringBuffer('// GERADO por tool/gen_tokens.dart a partir de design-system/tokens.json. Não editar.\n')
    ..writeln("import 'package:material_ui/material_ui.dart';\n")
    ..writeln('class TradeTokens {')
    ..writeln('  const TradeTokens._({');
  for (final n in sem.keys) {
    b.writeln('    required this.${camel(n)},');
  }
  b.writeln('  });\n');
  for (final n in sem.keys) {
    b.writeln('  final Color ${camel(n)};');
  }
  for (final k in ['spacing', 'radius']) {
    for (final t in (j[k]['tokens'] as List).cast<Map<String, dynamic>>()) {
      b.writeln('  final double ${camel(t['name'])} = ${px(t['value']).toDouble()};');
    }
  }
  for (final theme in ['light', 'dark']) {
    b.writeln('\n  static const $theme = TradeTokens._(');
    for (final e in sem.entries) {
      b.writeln('    ${camel(e.key)}: Color(${hex(resolve(e.value[theme]!))}),');
    }
    b.writeln('  );');
  }
  b.writeln('}');

  // Estilos de texto (sem cor: a cor vem do tema).
  b.writeln('\nclass TradeType {');
  b.writeln("  static const sansFamily = 'PlusJakartaSans';");
  b.writeln("  static const monoFamily = 'SpaceMono';");
  for (final g in (j['type']['groups'] as List).cast<Map<String, dynamic>>()) {
    for (final t in (g['styles'] as List).cast<Map<String, dynamic>>()) {
      final size = px(t['fontSize']);
      final ls = t['letterSpacing'] == null ? 0 : num.parse((t['letterSpacing'] as String).replaceAll('em', '')) * size;
      final family = g['family'] == 'mono' ? 'monoFamily' : 'sansFamily';
      b.writeln('  static const ${camel(t['name'])} = TextStyle(fontFamily: $family, fontSize: $size, '
          'height: ${(px(t['lineHeight']) / size).toStringAsFixed(4)}, fontWeight: FontWeight.w${t['fontWeight']}, '
          'letterSpacing: ${ls.toStringAsFixed(3)});');
    }
  }
  b.writeln('}');
  File('lib/theme/tokens.g.dart').writeAsStringSync(b.toString());
}

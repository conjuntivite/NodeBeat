import 'package:material_ui/material_ui.dart';

import '../theme/theme.dart';

/// Bandeira do pais (asset local, 20x15). O nome do pais aparece ao lado.
class Bandeira extends StatelessWidget {
  const Bandeira(this.cc, {super.key});
  final String? cc;

  @override
  Widget build(BuildContext context) {
    const vazio = SizedBox(width: 20, height: 15);
    final c = cc;
    if (c == null || c.isEmpty) return vazio;
    return Image.asset(
      'assets/bandeiras/${c.toLowerCase()}.png',
      width: 20,
      height: 15,
      excludeFromSemantics: true,
      // borda 1 px por cima (20x15 no total): bandeiras de faixa branca não somem no tema claro
      frameBuilder: (_, child, _, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(border: Border.all(color: tokensOf(context).borderSubtle)),
        child: child,
      ),
      errorBuilder: (_, _, _) => vazio,
    );
  }
}

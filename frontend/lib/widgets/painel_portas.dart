import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';

const _porGrupo = 12;

/// Número natural no nome ("0/12" -> 12, "ether5" -> 5); sem número vai para o fim.
int _numero(String nome) => int.tryParse(RegExp(r'(\d+)\D*$').firstMatch(nome)?.group(1) ?? '') ?? 1 << 30;

bool _sfp(String n) => n.toLowerCase().startsWith('sfp') || n.toLowerCase().startsWith('qsfp');

/// Frente do equipamento, estilo UniFi: grupos de 12, ímpar em cima / par embaixo, SFP à direita.
class PainelPortas extends StatelessWidget {
  const PainelPortas({super.key, required this.portas, this.aoTocar});
  final List<PortaVista> portas;
  final void Function(PortaVista)? aoTocar;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    int cmp(PortaVista a, PortaVista b) => _numero(a.nome).compareTo(_numero(b.nome));
    final normais = portas.where((p) => !_sfp(p.nome)).toList()..sort(cmp);
    final sfps = portas.where((p) => _sfp(p.nome)).toList()..sort(cmp);
    return Wrap(
      spacing: t.space4,
      runSpacing: t.space4,
      children: [
        for (var i = 0; i < normais.length; i += _porGrupo)
          _grupo(context, normais.sublist(i, i + _porGrupo > normais.length ? normais.length : i + _porGrupo)),
        if (sfps.isNotEmpty) _grupo(context, sfps),
      ],
    );
  }

  Widget _grupo(BuildContext context, List<PortaVista> g) {
    final t = tokensOf(context);
    // Posição 0,2,4... = fileira de cima (portas ímpares); 1,3,5... = embaixo.
    Widget fileira(int resto) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = resto; i < g.length; i += 2) Padding(padding: EdgeInsets.all(t.space1 / 2), child: _porta(context, g[i])),
        ]);
    return Column(mainAxisSize: MainAxisSize.min, children: [fileira(0), fileira(1)]);
  }

  Widget _porta(BuildContext context, PortaVista p) {
    final t = tokensOf(context);
    final cor = switch (p.estado) { 'up' => t.positiveFill, 'caiu' => t.negativeFill, _ => t.borderSubtle };
    final txt = switch (p.estado) { 'up' => 'com link', 'caiu' => 'caiu', _ => 'sem link' };
    final rotulo = '${p.nome} · $txt';
    return Semantics(
      label: rotulo,
      button: aoTocar != null,
      child: Tooltip(
        message: rotulo,
        child: GestureDetector(
          onTap: aoTocar == null ? null : () => aoTocar!(p),
          child: Container(
            key: Key('porta-${p.nome}'),
            width: 24,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cor,
              borderRadius: BorderRadius.circular(t.radiusXs),
              border: p.uplink ? Border.all(color: t.fgPrimary, width: 2) : null,
            ),
            child: p.uplink ? Container(width: 6, height: 6, decoration: BoxDecoration(color: t.fgPrimary, shape: BoxShape.circle)) : null,
          ),
        ),
      ),
    );
  }
}

import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';

const _porGrupo = 12;
const _largPorta = 24.0, _altPorta = 20.0, _pontoUplink = 6.0, _bordaUplink = 2.0;
const _semNumero = 1 << 30;

/// Número natural no nome ("0/12" -> 12, "ether5" -> 5); sem número vai para o fim.
int _numero(String nome) => int.tryParse(RegExp(r'(\d+)\D*$').firstMatch(nome)?.group(1) ?? '') ?? _semNumero;

bool _sfp(String n) => n.toLowerCase().startsWith('sfp') || n.toLowerCase().startsWith('qsfp');

/// Frente do equipamento, estilo UniFi: grupos de 12, ímpar em cima / par embaixo, SFP à direita.
class PainelPortas extends StatelessWidget {
  const PainelPortas({super.key, required this.portas, this.aoTocar});
  final List<PortaVista> portas;
  final void Function(PortaVista)? aoTocar;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    int cmp(PortaVista a, PortaVista b) {
      final n = _numero(a.nome).compareTo(_numero(b.nome));
      return n != 0 ? n : a.nome.compareTo(b.nome);
    }
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
    // Número ímpar no nome = fileira de cima, par = embaixo; sem número, alterna por posição.
    final cima = <PortaVista>[], baixo = <PortaVista>[];
    var semNum = 0;
    for (final p in g) {
      final n = _numero(p.nome);
      final emCima = n == _semNumero ? semNum++ % 2 == 0 : n.isOdd;
      (emCima ? cima : baixo).add(p);
    }
    Widget fileira(List<PortaVista> l) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (final p in l) Padding(padding: EdgeInsets.all(t.space1 / 2), child: _porta(context, p)),
        ]);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [fileira(cima), fileira(baixo)]);
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
            width: _largPorta,
            height: _altPorta,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cor,
              borderRadius: BorderRadius.circular(t.radiusXs),
              border: p.uplink ? Border.all(color: t.fgPrimary, width: _bordaUplink) : null,
            ),
            child: p.uplink ? Container(width: _pontoUplink, height: _pontoUplink, decoration: BoxDecoration(color: t.fgPrimary, shape: BoxShape.circle)) : null,
          ),
        ),
      ),
    );
  }
}

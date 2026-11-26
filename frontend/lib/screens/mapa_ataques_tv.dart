import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../ataques/aba.dart';
import '../ataques/paletas.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/mapa_ataques.dart';

/// Aba da TV do NOC, pública (sem login): a paleta escolhida (guardada no navegador) é o tema da tela, sem menu lateral.
class MapaAtaquesTvScreen extends StatefulWidget {
  const MapaAtaquesTvScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<MapaAtaquesTvScreen> createState() => _MapaAtaquesTvScreenState();
}

class _MapaAtaquesTvScreenState extends State<MapaAtaquesTvScreen> {
  late PaletaMapa _paleta = paletaPorId(paletaTvSalva());

  void _escolher(PaletaMapa p) {
    salvarPaletaTv(p.id);
    setState(() => _paleta = p);
  }

  @override
  Widget build(BuildContext context) {
    // A paleta é o tema da TV inteira; o tema global (themeMode) não entra aqui.
    final p = _paleta;
    final t = tokensDaPaleta(p);
    return Theme(
      data: tradeTheme(p.escura ? Brightness.dark : Brightness.light, t),
      child: TokensDaTela(
        tokens: t,
        child: Scaffold(
          backgroundColor: t.bgPage,
          body: SafeArea(
            child: Column(children: [
              DecoratedBox(
                decoration: BoxDecoration(color: t.bgSurface, border: Border(bottom: BorderSide(color: t.borderSubtle))),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: t.space6, vertical: t.space3),
                  child: Row(children: [
                    Image.asset('assets/brand/nodebeat-icon-${p.escura ? 'dark' : 'light'}.png', width: 28, height: 28, excludeFromSemantics: true),
                    SizedBox(width: t.space3),
                    Text('Ataques às MKs', style: TradeType.heading3.copyWith(color: t.fgPrimary)),
                    const Spacer(),
                    const _Relogio(),
                    SizedBox(width: t.space3),
                    _SeletorPaleta(atual: p, aoEscolher: _escolher),
                  ]),
                ),
              ),
              Expanded(
                child: MapaAtaques(api: widget.api, tv: true, paleta: p),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SeletorPaleta extends StatelessWidget {
  const _SeletorPaleta({required this.atual, required this.aoEscolher});
  final PaletaMapa atual;
  final ValueChanged<PaletaMapa> aoEscolher;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return PopupMenuButton<PaletaMapa>(
      tooltip: 'Paleta do mapa',
      onSelected: aoEscolher,
      itemBuilder: (_) => [
        for (final p in paletasMapa)
          PopupMenuItem(
            value: p,
            child: Row(children: [
              _Miniatura(p),
              SizedBox(width: t.space3),
              Expanded(child: Text(p.nome, style: TradeType.bodyMd.copyWith(color: t.fgPrimary))),
              if (p.id == atual.id) Icon(Icons.check, size: 16, color: t.fgPrimary),
            ]),
          ),
      ],
      // miniatura + texto em vez de ícone: a fonte de ícones sem hash fica horas no cache do navegador (Cloudflare)
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: t.space3, vertical: t.space1),
        decoration: BoxDecoration(border: Border.all(color: t.borderSubtle), borderRadius: BorderRadius.circular(t.radiusPill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _Miniatura(atual),
          SizedBox(width: t.space2),
          Text('Paleta', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        ]),
      ),
    );
  }
}

/// 40x24: fundo, faixa da terra e 3 pontos das vias.
class _Miniatura extends StatelessWidget {
  const _Miniatura(this.p);
  final PaletaMapa p;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      width: 40,
      height: 24,
      decoration: BoxDecoration(color: p.fundo, borderRadius: BorderRadius.circular(t.radiusSm), border: Border.all(color: p.borda)),
      child: Stack(children: [
        Positioned(left: 0, right: 0, top: 14, height: 6, child: ColoredBox(color: p.terra)),
        for (var i = 0; i < 3; i++)
          Positioned(left: 6.0 + i * 11, top: 5, child: Container(width: 5, height: 5, decoration: BoxDecoration(color: p.vias[i], shape: BoxShape.circle))),
      ]),
    );
  }
}

class _Relogio extends StatefulWidget {
  const _Relogio();
  @override
  State<_Relogio> createState() => _RelogioState();
}

class _RelogioState extends State<_Relogio> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    String d2(int v) => v.toString().padLeft(2, '0');
    return Text('${d2(n.hour)}:${d2(n.minute)}:${d2(n.second)}',
        style: TradeType.heading3.copyWith(color: tokensOf(context).fgSecondary, fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

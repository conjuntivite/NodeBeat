import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../ataques/aba.dart';
import '../ataques/paletas.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/mapa_ataques.dart';

/// Aba da TV do NOC, pública (sem login): o tema escolhido fica no navegador, sem menu lateral.
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

  void _salvar() => salvarTemaTv(themeMode.value == ThemeMode.dark ? 'escuro' : 'claro');

  @override
  void initState() {
    super.initState();
    final salvo = temaTvSalvo();
    // depois do quadro: mudar o tema no meio do build reconstruiria o MaterialApp acima
    if (salvo != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => themeMode.value = salvo == 'escuro' ? ThemeMode.dark : ThemeMode.light);
    }
    themeMode.addListener(_salvar);
  }

  @override
  void dispose() {
    themeMode.removeListener(_salvar);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final escuro = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: t.bgSubtle,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space6, vertical: t.space3),
            child: Row(children: [
              Image.asset('assets/brand/nodebeat-icon-${escuro ? 'dark' : 'light'}.png', width: 28, height: 28, excludeFromSemantics: true),
              SizedBox(width: t.space3),
              Text('Ataques às MKs', style: TradeType.heading3.copyWith(color: t.fgPrimary)),
              const Spacer(),
              const _Relogio(),
              SizedBox(width: t.space3),
              _SeletorPaleta(atual: _paleta, aoEscolher: _escolher),
              SizedBox(width: t.space2),
              const ThemeToggle(),
            ]),
          ),
          Expanded(
            child: MapaAtaques(api: widget.api, tv: true, paleta: _paleta),
          ),
        ]),
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
      icon: Icon(Icons.palette_outlined, color: t.fgSecondary),
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

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.g.dart';

// Exceção documentada à regra de tokens (spec 2026-11-26-paletas-mapa): são 8 conjuntos
// fechados, só do mapa de ataques da TV, então as cores ficam aqui como dados.

/// Login aceito: sempre vermelho, em qualquer paleta.
const corAceito = Color(0xFFEF4444);

class PaletaMapa {
  const PaletaMapa({
    required this.id,
    required this.nome,
    required this.fundo,
    required this.terra,
    required this.borda,
    required this.texto,
    required this.vias,
    required this.escura,
    required this.painel,
    required this.bordaPainel,
    required this.textoSec,
  });
  final String id, nome;
  final Color fundo, terra, borda;
  final Color texto; // ponto de destino e rótulos sobre o mapa
  final List<Color> vias; // SSH, TELNET, FTP, API, WINBOX, outros
  final bool escura; // base dos tokens de status (selos, alertas)
  final Color painel, bordaPainel, textoSec; // cabeçalho, lista ao vivo e tops da TV
}

const paletasMapa = <PaletaMapa>[
  PaletaMapa(id: 'ardosia', nome: 'Ardósia', fundo: Color(0xFF0F1620), terra: Color(0xFF2A3544), borda: Color(0xFF3A4757), texto: Color(0xFFF3F4F6),
      vias: [Color(0xFF60A5FA), Color(0xFFFB923C), Color(0xFF34D399), Color(0xFFFBBF24), Color(0xFFA78BFA), Color(0xFF94A3B8)],
      escura: true, painel: Color(0xFF151E2B), bordaPainel: Color(0xFF243041), textoSec: Color(0xFFA9B4C2)),
  PaletaMapa(id: 'cinza', nome: 'Cinza claro', fundo: Color(0xFFE6EAF0), terra: Color(0xFF9AA5B4), borda: Color(0xFF7D8999), texto: Color(0xFF111827),
      vias: [Color(0xFF2563EB), Color(0xFFEA580C), Color(0xFF059669), Color(0xFFB45309), Color(0xFF7C3AED), Color(0xFF475569)],
      escura: false, painel: Color(0xFFF4F6F9), bordaPainel: Color(0xFFC9D1DC), textoSec: Color(0xFF4B5563)),
  PaletaMapa(id: 'noite', nome: 'Noite', fundo: Color(0xFF05070B), terra: Color(0xFF1A222D), borda: Color(0xFF263140), texto: Color(0xFFFFFFFF),
      vias: [Color(0xFF22D3EE), Color(0xFFF97316), Color(0xFF4ADE80), Color(0xFFFACC15), Color(0xFFC084FC), Color(0xFF9CA3AF)],
      escura: true, painel: Color(0xFF0C1118), bordaPainel: Color(0xFF1C2430), textoSec: Color(0xFFA3ACB9)),
  PaletaMapa(id: 'oceano', nome: 'Oceano', fundo: Color(0xFF0A2540), terra: Color(0xFF1D4268), borda: Color(0xFF2C5A87), texto: Color(0xFFF8FAFC),
      vias: [Color(0xFF7DD3FC), Color(0xFFFDBA74), Color(0xFF86EFAC), Color(0xFFFDE047), Color(0xFFD8B4FE), Color(0xFFCBD5E1)],
      escura: true, painel: Color(0xFF0F2E4D), bordaPainel: Color(0xFF1E4468), textoSec: Color(0xFFB6C6D8)),
  PaletaMapa(id: 'grafite', nome: 'Grafite', fundo: Color(0xFF18181B), terra: Color(0xFF3F3F46), borda: Color(0xFF52525B), texto: Color(0xFFFAFAFA),
      vias: [Color(0xFF38BDF8), Color(0xFFFB923C), Color(0xFF4ADE80), Color(0xFFFACC15), Color(0xFFA78BFA), Color(0xFFA1A1AA)],
      escura: true, painel: Color(0xFF202024), bordaPainel: Color(0xFF34343A), textoSec: Color(0xFFA1A1AA)),
  PaletaMapa(id: 'papel', nome: 'Papel', fundo: Color(0xFFF7F7F4), terra: Color(0xFFD6D3CB), borda: Color(0xFFB8B4AA), texto: Color(0xFF1C1917),
      vias: [Color(0xFF1D4ED8), Color(0xFFC2410C), Color(0xFF047857), Color(0xFFA16207), Color(0xFF6D28D9), Color(0xFF57534E)],
      escura: false, painel: Color(0xFFFFFFFF), bordaPainel: Color(0xFFE2DFD8), textoSec: Color(0xFF57534E)),
  PaletaMapa(id: 'floresta', nome: 'Floresta', fundo: Color(0xFF0C1A14), terra: Color(0xFF1F3A2C), borda: Color(0xFF2D5240), texto: Color(0xFFF0FDF4),
      vias: [Color(0xFF7DD3FC), Color(0xFFFDBA74), Color(0xFFBEF264), Color(0xFFFDE047), Color(0xFFC4B5FD), Color(0xFFA8A29E)],
      escura: true, painel: Color(0xFF11231B), bordaPainel: Color(0xFF22392D), textoSec: Color(0xFFA7C4B3)),
  PaletaMapa(id: 'alto', nome: 'Alto contraste', fundo: Color(0xFF000000), terra: Color(0xFF3A3A3A), borda: Color(0xFF6B6B6B), texto: Color(0xFFFFFFFF),
      vias: [Color(0xFF00B7FF), Color(0xFFFF8A00), Color(0xFF00E676), Color(0xFFFFEA00), Color(0xFFB388FF), Color(0xFFFFFFFF)],
      escura: true, painel: Color(0xFF0A0A0A), bordaPainel: Color(0xFF4A4A4A), textoSec: Color(0xFFD4D4D4)),
];

/// Id nulo ou desconhecido cai em `ardosia`.
PaletaMapa paletaPorId(String? id) => paletasMapa.firstWhere((p) => p.id == id, orElse: () => paletasMapa.first);

PaletaMapa paletaPadrao(Brightness b) => paletaPorId(b == Brightness.light ? 'cinza' : 'ardosia');

/// Tokens da TV: a paleta vira o tema (fundo, painéis, textos e ação sem pink);
/// status, raios e espaços vêm da base clara/escura.
TradeTokens tokensDaPaleta(PaletaMapa p) {
  final acao = p.vias[0];
  final base = p.escura ? TradeTokens.dark : TradeTokens.light;
  return base.copyWith(
    bgPage: p.fundo,
    bgSubtle: p.fundo,
    bgSurface: p.painel,
    bgElevated: p.painel,
    bgHover: p.texto.withValues(alpha: 0.08),
    borderSubtle: p.bordaPainel,
    borderStrong: p.bordaPainel,
    fgPrimary: p.texto,
    fgSecondary: p.textoSec,
    fgMuted: p.textoSec,
    actionPrimary: acao,
    actionAccent: acao,
    focusRing: acao,
    bgBrand: acao,
    bgBrandDeep: acao,
    brandHover: acao,
    brandText: acao,
    chart1: acao,
    brandTint: acao.withValues(alpha: 0.15),
    actionPrimaryFg: p.fundo,
    fgOnBrand: p.fundo,
    bgInverse: p.texto, // tooltip e snackbar sem pink
    fgInverse: p.fundo,
    fgDisabled: p.textoSec,
    chartGrid: p.bordaPainel,
    chartAxis: p.bordaPainel,
    chart6: p.vias[5],
    risk: base.negative,
    riskFill: base.negative,
  );
}

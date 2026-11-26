import 'package:material_ui/material_ui.dart';

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
  });
  final String id, nome;
  final Color fundo, terra, borda;
  final Color texto; // ponto de destino e rótulos sobre o mapa
  final List<Color> vias; // SSH, TELNET, FTP, API, WINBOX, outros
}

const paletasMapa = <PaletaMapa>[
  PaletaMapa(id: 'ardosia', nome: 'Ardósia', fundo: Color(0xFF0F1620), terra: Color(0xFF2A3544), borda: Color(0xFF3A4757), texto: Color(0xFFF3F4F6),
      vias: [Color(0xFF60A5FA), Color(0xFFFB923C), Color(0xFF34D399), Color(0xFFFBBF24), Color(0xFFA78BFA), Color(0xFF94A3B8)]),
  PaletaMapa(id: 'cinza', nome: 'Cinza claro', fundo: Color(0xFFE6EAF0), terra: Color(0xFF9AA5B4), borda: Color(0xFF7D8999), texto: Color(0xFF111827),
      vias: [Color(0xFF2563EB), Color(0xFFEA580C), Color(0xFF059669), Color(0xFFB45309), Color(0xFF7C3AED), Color(0xFF475569)]),
  PaletaMapa(id: 'noite', nome: 'Noite', fundo: Color(0xFF05070B), terra: Color(0xFF1A222D), borda: Color(0xFF263140), texto: Color(0xFFFFFFFF),
      vias: [Color(0xFF22D3EE), Color(0xFFF97316), Color(0xFF4ADE80), Color(0xFFFACC15), Color(0xFFC084FC), Color(0xFF9CA3AF)]),
  PaletaMapa(id: 'oceano', nome: 'Oceano', fundo: Color(0xFF0A2540), terra: Color(0xFF1D4268), borda: Color(0xFF2C5A87), texto: Color(0xFFF8FAFC),
      vias: [Color(0xFF7DD3FC), Color(0xFFFDBA74), Color(0xFF86EFAC), Color(0xFFFDE047), Color(0xFFD8B4FE), Color(0xFFCBD5E1)]),
  PaletaMapa(id: 'grafite', nome: 'Grafite', fundo: Color(0xFF18181B), terra: Color(0xFF3F3F46), borda: Color(0xFF52525B), texto: Color(0xFFFAFAFA),
      vias: [Color(0xFF38BDF8), Color(0xFFFB923C), Color(0xFF4ADE80), Color(0xFFFACC15), Color(0xFFA78BFA), Color(0xFFA1A1AA)]),
  PaletaMapa(id: 'papel', nome: 'Papel', fundo: Color(0xFFF7F7F4), terra: Color(0xFFD6D3CB), borda: Color(0xFFB8B4AA), texto: Color(0xFF1C1917),
      vias: [Color(0xFF1D4ED8), Color(0xFFC2410C), Color(0xFF047857), Color(0xFFA16207), Color(0xFF6D28D9), Color(0xFF57534E)]),
  PaletaMapa(id: 'floresta', nome: 'Floresta', fundo: Color(0xFF0C1A14), terra: Color(0xFF1F3A2C), borda: Color(0xFF2D5240), texto: Color(0xFFF0FDF4),
      vias: [Color(0xFF7DD3FC), Color(0xFFFDBA74), Color(0xFFBEF264), Color(0xFFFDE047), Color(0xFFC4B5FD), Color(0xFFA8A29E)]),
  PaletaMapa(id: 'alto', nome: 'Alto contraste', fundo: Color(0xFF000000), terra: Color(0xFF3A3A3A), borda: Color(0xFF6B6B6B), texto: Color(0xFFFFFFFF),
      vias: [Color(0xFF00B7FF), Color(0xFFFF8A00), Color(0xFF00E676), Color(0xFFFFEA00), Color(0xFFB388FF), Color(0xFFFFFFFF)]),
];

/// Id nulo ou desconhecido cai em `ardosia`.
PaletaMapa paletaPorId(String? id) => paletasMapa.firstWhere((p) => p.id == id, orElse: () => paletasMapa.first);

PaletaMapa paletaPadrao(Brightness b) => paletaPorId(b == Brightness.light ? 'cinza' : 'ardosia');

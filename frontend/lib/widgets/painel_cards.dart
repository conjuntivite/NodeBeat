import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'common.dart';

/// Sobretítulo em caixa alta (mono). A caixa alta vem do texto, não de estilo.
Widget eyebrow(String texto, {required Color cor}) =>
    Text(texto.toUpperCase(), style: TradeType.eyebrow.copyWith(color: cor));

/// Selo em pílula: cor semântica no texto e no ponto, fundo com a mesma cor em 12%.
class Selo extends StatelessWidget {
  const Selo(this.texto, {super.key, required this.cor, this.ponto = false});
  final String texto;
  final Color cor;
  final bool ponto;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: t.space3, vertical: t.space1),
      decoration: BoxDecoration(color: cor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(t.radiusPill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (ponto) ...[
          Container(width: 8, height: 8, decoration: BoxDecoration(color: cor, shape: BoxShape.circle)),
          SizedBox(width: t.space2),
        ],
        Text(texto, style: TradeType.label.copyWith(color: cor, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _Hachura extends CustomPainter {
  _Hachura(this.cor);
  final Color cor;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = cor
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_Hachura old) => old.cor != cor;
}

String _plural(int n, String um, String varios) => '$n ${n == 1 ? um : varios}';

/// Card de destaque (cor de marca): veredito em uma frase e a contagem do semáforo.
/// O fundo e o texto da marca não mudam com o tema; os pontos usam as cores do tema claro por isso.
class CartaoSituacao extends StatelessWidget {
  const CartaoSituacao({
    super.key,
    required this.frase,
    required this.verdes,
    required this.amarelas,
    required this.vermelhas,
    this.eyebrowTexto = 'Situação',
  });
  final String frase, eyebrowTexto;
  final int verdes, amarelas, vermelhas;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    const claro = TradeTokens.light;
    Widget ficha(Color ponto, String texto) => Container(
          padding: EdgeInsets.symmetric(horizontal: t.space3, vertical: t.space1),
          decoration: BoxDecoration(color: t.fgOnBrand.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(t.radiusPill)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: ponto, shape: BoxShape.circle)),
            SizedBox(width: t.space2),
            Text(texto, style: TradeType.label.copyWith(color: t.fgOnBrand)),
          ]),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(t.radiusXl),
      child: Container(
        color: t.bgBrand,
        child: Stack(children: [
          Positioned(
            right: -t.space8,
            top: -t.space8,
            width: 180,
            height: 180,
            child: IgnorePointer(
              child: ClipOval(child: CustomPaint(painter: _Hachura(t.fgOnBrand.withValues(alpha: 0.14)))),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(t.space6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              eyebrow(eyebrowTexto, cor: t.fgOnBrand.withValues(alpha: 0.75)),
              SizedBox(height: t.space3),
              Text(frase, style: TradeType.heading2.copyWith(color: t.fgOnBrand)),
              SizedBox(height: t.space5),
              Wrap(spacing: t.space2, runSpacing: t.space2, children: [
                ficha(claro.positive, _plural(verdes, 'verde', 'verdes')),
                ficha(claro.warning, _plural(amarelas, 'amarela', 'amarelas')),
                ficha(claro.negative, _plural(vermelhas, 'vermelha', 'vermelhas')),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// MKs que pedem uma olhada, com selo do semáforo; toque abre a MK.
class PainelAtencao extends StatelessWidget {
  const PainelAtencao({super.key, required this.itens, required this.aoAbrir});
  final List<AtencaoItem> itens;
  final void Function(String mkId) aoAbrir;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final titulo = itens.isEmpty
        ? 'Tudo certo'
        : itens.length == 1
            ? '1 MK pede uma olhada'
            : '${itens.length} MKs pedem uma olhada';
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        eyebrow('Atenção agora', cor: t.fgMuted),
        SizedBox(height: t.space2),
        Row(children: [
          if (itens.isEmpty) ...[Icon(Icons.check_circle_outline, size: 20, color: t.positive), SizedBox(width: t.space2)],
          Expanded(child: Text(titulo, style: TradeType.heading3.copyWith(color: t.fgPrimary))),
        ]),
        SizedBox(height: t.space2),
        for (final a in itens)
          InkWell(
            key: Key('atencao-${a.mkId}'),
            borderRadius: BorderRadius.circular(t.radiusMd),
            onTap: () => aoAbrir(a.mkId),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: t.space2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                a.semaforo == 'vermelho'
                    ? Selo('Vermelho', cor: t.negative, ponto: true)
                    : Selo('Amarelo', cor: t.warning, ponto: true),
                SizedBox(width: t.space3),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.nome, style: TradeType.heading4.copyWith(color: t.fgPrimary)),
                    Text(a.motivo, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
                  ]),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

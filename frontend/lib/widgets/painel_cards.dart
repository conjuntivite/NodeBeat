import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'common.dart';
import 'graficos.dart';
import 'painel_textos.dart';

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
                    ? Pilula('Vermelho', cor: t.negative, ponto: true)
                    : Pilula('Amarelo', cor: t.warning, ponto: true),
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

const _tabular = [FontFeature.tabularFigures()];

Color _corEstado(TradeTokens t, String estado) => switch (estado) {
      'esperado' => t.info,
      'normal' => t.positive,
      'atencao' => t.warning,
      _ => t.negative,
    };

/// Card de uma categoria de eventos: o número, se é bom ou ruim e o que ele significa.
class CartaoCategoria extends StatelessWidget {
  const CartaoCategoria({
    super.key,
    required this.categoria,
    required this.total,
    required this.estado,
    required this.serie,
    required this.aoVerDetalhes,
  });
  final String categoria;
  final int total;
  final EstadoCategoria? estado;
  final List<PontoSerie> serie;
  final VoidCallback aoVerDetalhes;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final delta = estado?.deltaPct;
    // Acesso é ruído da internet: a variação fica neutra. Nas demais, subir é ruim e cair é bom.
    final corDelta = delta == null
        ? t.fgMuted
        : categoria == 'acesso' || delta == 0
            ? t.fgSecondary
            : delta > 0
                ? t.negative
                : t.positive;
    final pontos = [for (var i = 0; i < serie.length; i++) FlSpot(i.toDouble(), (serie[i].valores[categoria] ?? 0).toDouble())];
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: eyebrow(rotuloCategoria[categoria] ?? categoria, cor: t.fgMuted)),
          if (estado != null) Pilula(rotuloEstado(estado!.estado), cor: _corEstado(t, estado!.estado)),
        ]),
        SizedBox(height: t.space3),
        Text(milhar(total),
            key: Key('total-$categoria'),
            style: TradeType.dataXl.copyWith(color: t.fgPrimary, fontFeatures: _tabular)),
        SizedBox(height: t.space1),
        Text(textoDelta(delta), style: TradeType.dataSm.copyWith(color: corDelta, fontFeatures: _tabular)),
        SizedBox(height: t.space3),
        SizedBox(
          height: 36,
          child: pontos.length < 2
              ? null
              : LineChart(LineChartData(
                  minY: 0,
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: false),
                  lineTouchData: const LineTouchData(enabled: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: pontos,
                      isCurved: true,
                      color: corCategoria(t, categoria),
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                )),
        ),
        SizedBox(height: t.space3),
        Container(
          padding: EdgeInsets.only(top: t.space3),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: t.borderSubtle))),
          child: Text(explicacaoCategoria[categoria] ?? '', style: TradeType.bodySm.copyWith(color: t.fgSecondary)),
        ),
        SizedBox(height: t.space3),
        InkWell(
          onTap: aoVerDetalhes,
          child: Text('Ver detalhes →', style: TradeType.label.copyWith(color: t.brandText, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

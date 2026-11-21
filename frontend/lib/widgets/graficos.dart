import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'common.dart' show Pilula;

const rotuloCategoria = {
  'acesso': 'Acesso',
  'autenticacao': 'Autenticação',
  'vpn': 'VPN',
  'erros': 'Erros',
};

/// Cor de cada categoria; o gráfico sempre traz o rótulo ao lado (cor nunca é a única pista).
Color corCategoria(TradeTokens t, String cat) => switch (cat) {
      'acesso' => t.negative,
      'autenticacao' => t.info,
      'vpn' => t.risk,
      _ => t.warning,
    };

class _Vazio extends StatelessWidget {
  const _Vazio();
  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return SizedBox(
      height: 96,
      child: Center(child: Text('Sem eventos no período', style: TradeType.bodyMd.copyWith(color: t.fgMuted))),
    );
  }
}

class _Legenda extends StatelessWidget {
  const _Legenda(this.itens);
  final List<(Color, String)> itens;
  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Wrap(spacing: t.space4, runSpacing: t.space1, children: [
      for (final (cor, texto) in itens)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: cor, borderRadius: BorderRadius.circular(2))),
          SizedBox(width: t.space2),
          Flexible(child: Text(texto, overflow: TextOverflow.ellipsis, style: TradeType.bodyMd.copyWith(color: t.fgPrimary))),
        ]),
    ]);
  }
}

/// Barras horizontais com rótulo e número (nomes de MK longos não cabem no eixo de um gráfico vertical).
class GraficoBarras extends StatelessWidget {
  const GraficoBarras({super.key, required this.dados, this.cor});
  final List<(String, int)> dados;
  final Color? cor;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    if (dados.isEmpty) return const _Vazio();
    final maximo = dados.map((d) => d.$2).reduce((a, b) => a > b ? a : b);
    return Column(children: [
      for (final (nome, n) in dados)
        Padding(
          padding: EdgeInsets.symmetric(vertical: t.space1),
          child: Row(children: [
            Expanded(flex: 5, child: Text(nome, overflow: TextOverflow.ellipsis, style: TradeType.bodyMd.copyWith(color: t.fgPrimary))),
            Expanded(
              flex: 6,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(t.radiusPill),
                child: LinearProgressIndicator(
                  value: maximo == 0 ? 0 : n / maximo,
                  minHeight: 10,
                  color: cor ?? t.info,
                  backgroundColor: t.borderSubtle,
                ),
              ),
            ),
            SizedBox(width: t.space2),
            SizedBox(width: 40, child: Text('$n', textAlign: TextAlign.end, style: TradeType.dataSm.copyWith(color: t.fgPrimary, fontFeatures: const [FontFeature.tabularFigures()]))),
          ]),
        ),
    ]);
  }
}

String _rotuloHora(DateTime utc, int total) {
  final d = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return total > 48 ? '${two(d.day)}/${two(d.month)}' : '${two(d.hour)}h';
}

int _somaPonto(PontoSerie p, List<String> series) => series.fold(0, (a, s) => a + (p.valores[s] ?? 0));

class GraficoLinha extends StatelessWidget {
  const GraficoLinha({super.key, required this.pontos, required this.series});
  final List<PontoSerie> pontos;
  final List<String> series;

  /// "03h · 812": o ponto da série com mais eventos; `null` sem eventos.
  static String? picoDe(List<PontoSerie> pontos, List<String> series) {
    if (pontos.isEmpty) return null;
    final p = pontos.reduce((a, b) => _somaPonto(b, series) > _somaPonto(a, series) ? b : a);
    final n = _somaPonto(p, series);
    return n == 0 ? null : '${_rotuloHora(p.hora, pontos.length)} · $n';
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final pico = picoDe(pontos, series);
    if (pico == null) return const _Vazio();
    final passo = (pontos.length / 6).ceil().clamp(1, pontos.length);
    int total(String s) => pontos.fold(0, (a, p) => a + (p.valores[s] ?? 0));
    final principal = series.reduce((a, b) => total(b) > total(a) ? b : a);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Align(alignment: Alignment.centerRight, child: Pilula('Pico: $pico', cor: t.info)),
      SizedBox(height: t.space3),
      SizedBox(
        height: 180,
        child: LineChart(LineChartData(
          minY: 0,
          gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: t.borderSubtle, strokeWidth: 1)),
          borderData: FlBorderData(show: false),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => t.bgInverse,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem('${rotuloCategoria[series[s.barIndex]] ?? series[s.barIndex]}: ${s.y.toInt()}',
                      TradeType.label.copyWith(color: t.fgInverse)),
              ],
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, getTitlesWidget: (v, meta) {
              if (v == meta.max || v == meta.min && v != 0) return const SizedBox.shrink();
              return Text(v.toInt().toString(), style: TradeType.bodySm.copyWith(color: t.fgMuted));
            })),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 24, interval: passo.toDouble(), getTitlesWidget: (v, meta) {
              final i = v.toInt();
              if (i < 0 || i >= pontos.length) return const SizedBox.shrink();
              return Padding(
                padding: EdgeInsets.only(top: t.space2),
                child: Text(_rotuloHora(pontos[i].hora, pontos.length), style: TradeType.bodySm.copyWith(color: t.fgMuted)),
              );
            })),
          ),
          lineBarsData: [
            for (final s in series)
              LineChartBarData(
                spots: [for (var i = 0; i < pontos.length; i++) FlSpot(i.toDouble(), (pontos[i].valores[s] ?? 0).toDouble())],
                color: corCategoria(t, s),
                barWidth: 2.5,
                isCurved: true,
                curveSmoothness: 0.2,
                preventCurveOverShooting: true,
                dotData: const FlDotData(show: false),
                belowBarData: s == principal
                    ? BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [corCategoria(t, s).withValues(alpha: 0.22), corCategoria(t, s).withValues(alpha: 0)],
                        ),
                      )
                    : BarAreaData(show: false),
              ),
          ],
        )),
      ),
      SizedBox(height: t.space3),
      _Legenda([for (final s in series) (corCategoria(t, s), rotuloCategoria[s] ?? s)]),
    ]);
  }
}

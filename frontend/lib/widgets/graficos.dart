import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';

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

class GraficoPizza extends StatelessWidget {
  const GraficoPizza({super.key, required this.dados});
  final Map<String, int> dados;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    if (dados.values.every((v) => v == 0)) return const _Vazio();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 160,
        child: PieChart(PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 36,
          sections: [
            for (final e in dados.entries)
              if (e.value > 0)
                PieChartSectionData(value: e.value.toDouble(), color: corCategoria(t, e.key), title: '', radius: 28),
          ],
        )),
      ),
      SizedBox(height: t.space3),
      _Legenda([for (final e in dados.entries) (corCategoria(t, e.key), '${rotuloCategoria[e.key] ?? e.key}: ${e.value}')]),
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
                  backgroundColor: t.bgSurface,
                ),
              ),
            ),
            SizedBox(width: t.space2),
            SizedBox(width: 40, child: Text('$n', textAlign: TextAlign.end, style: TradeType.dataSm.copyWith(color: t.fgPrimary))),
          ]),
        ),
    ]);
  }
}

class GraficoLinha extends StatelessWidget {
  const GraficoLinha({super.key, required this.pontos, required this.series});
  final List<PontoSerie> pontos;
  final List<String> series;

  String _rotulo(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return pontos.length > 48 ? '${two(d.day)}/${two(d.month)}' : '${two(d.hour)}h';
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final total = pontos.fold<int>(0, (a, p) => a + p.valores.values.fold(0, (x, y) => x + y));
    if (pontos.isEmpty || total == 0) return const _Vazio();
    final passo = (pontos.length / 6).ceil().clamp(1, pontos.length);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 180,
        child: LineChart(LineChartData(
          minY: 0,
          gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: t.borderSubtle, strokeWidth: 1)),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, getTitlesWidget: (v, meta) {
              if (v == meta.max || v == meta.min && v != 0) return const SizedBox.shrink();
              return Text(v.toInt().toString(), style: TradeType.bodyMd.copyWith(color: t.fgMuted, fontSize: 11));
            })),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 24, interval: passo.toDouble(), getTitlesWidget: (v, meta) {
              final i = v.toInt();
              if (i < 0 || i >= pontos.length) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_rotulo(pontos[i].hora), style: TradeType.bodyMd.copyWith(color: t.fgMuted, fontSize: 11)),
              );
            })),
          ),
          lineBarsData: [
            for (final s in series)
              LineChartBarData(
                spots: [for (var i = 0; i < pontos.length; i++) FlSpot(i.toDouble(), (pontos[i].valores[s] ?? 0).toDouble())],
                color: corCategoria(t, s),
                barWidth: 2,
                dotData: const FlDotData(show: false),
              ),
          ],
        )),
      ),
      SizedBox(height: t.space3),
      _Legenda([for (final s in series) (corCategoria(t, s), rotuloCategoria[s] ?? s)]),
    ]);
  }
}

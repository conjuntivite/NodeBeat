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
  // grupos de evento dos switches
  'clientes': 'Clientes com fio',
  'alertas': 'Alertas',
  'poe': 'PoE religado',
  'mudancas': 'Mudanças',
};

/// Cor de cada categoria; o gráfico sempre traz o rótulo ao lado (cor nunca é a única pista).
/// Série de gráfico por categoria: chart-1..4 na ordem fixa (a cor segue a categoria, nunca o ranking).
Color corCategoria(TradeTokens t, String cat) => switch (cat) {
      'autenticacao' => t.chart1,
      'acesso' => t.chart2,
      'vpn' || 'poe' => t.chart3,
      'alertas' => t.chart2,
      'clientes' => t.chart1,
      _ => t.chart4,
    };

class _Vazio extends StatelessWidget {
  const _Vazio([this.texto = 'Sem eventos no período']);
  final String texto;
  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return SizedBox(
      height: 96,
      child: Center(child: Text(texto, style: TradeType.bodyMd.copyWith(color: t.fgMuted))),
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

/// Formato pelo intervalo coberto: > 48 h → dd/mm; ≤ 2 h → HH:mm; senão HHh.
String _rotuloHora(DateTime utc, List<PontoSerie> pontos) {
  final d = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final span = pontos.last.hora.difference(pontos.first.hora);
  if (span > const Duration(hours: 48)) return '${two(d.day)}/${two(d.month)}';
  if (span <= const Duration(hours: 2)) return '${two(d.hour)}:${two(d.minute)}';
  return '${two(d.hour)}h';
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
    return n == 0 ? null : '${_rotuloHora(p.hora, pontos)} · $n';
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final pico = picoDe(pontos, series);
    if (pico == null) return const _Vazio();
    final passo = (pontos.length / 6).ceil().clamp(1, pontos.length);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Align(alignment: Alignment.centerRight, child: Pilula('Pico: $pico', cor: t.info)),
      SizedBox(height: t.space3),
      SizedBox(
        height: 180,
        child: LineChart(LineChartData(
          minY: 0,
          gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: t.chartGrid, strokeWidth: 1)),
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
                child: Text(_rotuloHora(pontos[i].hora, pontos), style: TradeType.bodySm.copyWith(color: t.fgMuted)),
              );
            })),
          ),
          lineBarsData: [
            for (final s in series)
              LineChartBarData(
                spots: [for (var i = 0; i < pontos.length; i++) FlSpot(i.toDouble(), (pontos[i].valores[s] ?? 0).toDouble())],
                color: corCategoria(t, s),
                barWidth: 2, // linha de 2 px, sem área nem gradiente
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: false),
              ),
          ],
        )),
      ),
      SizedBox(height: t.space3),
      _Legenda([for (final s in series) (corCategoria(t, s), rotuloCategoria[s] ?? s)]),
    ]);
  }
}

/// Rosca com legenda (valor e %) e alternância para tabela, para quem não distingue as cores.
class GraficoPizza extends StatefulWidget {
  const GraficoPizza({super.key, required this.fatias, this.centro});
  final List<(String, num)> fatias;
  final String? centro;

  @override
  State<GraficoPizza> createState() => _GraficoPizzaState();
}

class _GraficoPizzaState extends State<GraficoPizza> {
  bool _tabela = false;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final total = widget.fatias.fold<num>(0, (a, f) => a + f.$2);
    if (total <= 0) return const _Vazio();
    final cores = [t.chart1, t.chart2, t.chart3, t.chart4, t.chart5, t.chart6];
    String pct(num v) => '${(v / total * 100).round()}%';
    String valor(num v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);
    final cell = TradeType.bodyMd.copyWith(color: t.fgPrimary, fontFeatures: const [FontFeature.tabularFigures()]);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => setState(() => _tabela = !_tabela),
          child: Text(_tabela ? 'Ver como gráfico' : 'Ver como tabela'),
        ),
      ),
      if (_tabela)
        for (final (nome, v) in widget.fatias)
          Padding(
            padding: EdgeInsets.symmetric(vertical: t.space1),
            child: Row(children: [
              Expanded(child: Text(nome, overflow: TextOverflow.ellipsis, style: cell)),
              Text(valor(v), style: cell),
              SizedBox(width: t.space4),
              SizedBox(width: 48, child: Text(pct(v), textAlign: TextAlign.end, style: cell)),
            ]),
          )
      else ...[
        SizedBox(
          height: 160,
          child: Stack(alignment: Alignment.center, children: [
            PieChart(PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 48,
              pieTouchData: PieTouchData(enabled: false),
              sections: [
                for (var i = 0; i < widget.fatias.length; i++)
                  PieChartSectionData(
                    value: widget.fatias[i].$2.toDouble(),
                    color: cores[i % cores.length],
                    radius: 24,
                    showTitle: false,
                  ),
              ],
            )),
            if (widget.centro != null) Text(widget.centro!, style: TradeType.dataSm.copyWith(color: t.fgPrimary)),
          ]),
        ),
        SizedBox(height: t.space3),
        _Legenda([
          for (var i = 0; i < widget.fatias.length; i++)
            (cores[i % cores.length], '${widget.fatias[i].$1} · ${valor(widget.fatias[i].$2)} (${pct(widget.fatias[i].$2)})'),
        ]),
      ],
    ]);
  }
}

/// Linha de uso ao longo do tempo, com linha de limite e projeção tracejada de 30 dias.
class GraficoCapacidade extends StatelessWidget {
  const GraficoCapacidade({super.key, required this.pontos, this.limite, this.tendenciaDia, this.unidade = ''});
  final List<(DateTime, double)> pontos;
  final double? limite, tendenciaDia;
  final String unidade;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    if (pontos.isEmpty) return const _Vazio('Sem dados ainda');
    final ini = pontos.first.$1;
    double dias(DateTime d) => d.difference(ini).inMinutes / 1440;
    final spots = [for (final p in pontos) FlSpot(dias(p.$1), p.$2)];
    final ultimo = spots.last;
    final proj = tendenciaDia == null ? null : [ultimo, FlSpot(ultimo.x + 30, ultimo.y + tendenciaDia! * 30)];
    String data(double x) {
      final d = ini.add(Duration(minutes: (x * 1440).round())).toLocal();
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
    }

    final xMax = proj?.last.x ?? ultimo.x;
    final topo = [...spots.map((s) => s.y), ?proj?.last.y, ?limite].reduce((a, b) => a > b ? a : b);
    return SizedBox(
      height: 180,
      child: LineChart(LineChartData(
        minY: 0,
        maxY: topo <= 0 ? 1 : topo * 1.1,
        minX: 0,
        maxX: xMax <= 0 ? 1 : xMax,
        gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: t.chartGrid, strokeWidth: 1)),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => t.bgInverse,
            getTooltipItems: (ss) => [
              for (final s in ss) LineTooltipItem('${data(s.x)}: ${s.y.toStringAsFixed(1)} $unidade', TradeType.label.copyWith(color: t.fgInverse)),
            ],
          ),
        ),
        extraLinesData: ExtraLinesData(horizontalLines: [
          if (limite != null) HorizontalLine(y: limite!, color: t.negative, strokeWidth: 1, dashArray: [4, 4]),
        ]),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36, getTitlesWidget: (v, meta) {
            if (v == meta.max) return const SizedBox.shrink();
            return Text(v.toStringAsFixed(0), style: TradeType.bodySm.copyWith(color: t.fgMuted));
          })),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 24, getTitlesWidget: (v, meta) {
            if (v == meta.max || (v == meta.min && v != 0)) return const SizedBox.shrink();
            return Padding(padding: EdgeInsets.only(top: t.space2), child: Text(data(v), style: TradeType.bodySm.copyWith(color: t.fgMuted)));
          })),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            color: t.chart1,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
          if (proj != null)
            LineChartBarData(
              spots: proj,
              color: t.chart1,
              barWidth: 2,
              dashArray: [6, 4],
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: false),
            ),
        ],
      )),
    );
  }
}

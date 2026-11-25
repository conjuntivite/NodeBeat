import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/graficos.dart';
import '../widgets/shell.dart';

const _grupos = ['clientes', 'alertas', 'poe', 'mudancas'];
const _diasMinimos = 7;

/// "+40% ↗" / "−12% ↘" / "0% →"; `null` sem base de comparação (período anterior 0 ou ausente).
String? textoVariacao(int? atual, int? anterior) {
  if (atual == null || anterior == null || anterior == 0) return null;
  final pct = ((atual - anterior) * 100 / anterior).round();
  if (pct == 0) return '0% →';
  return pct > 0 ? '+$pct% ↗' : '−${pct.abs()}% ↘';
}

/// Aba Switches da tela Eventos: indicadores, gráficos, capacidade por switch e últimos eventos.
class PainelSwitches extends StatelessWidget {
  const PainelSwitches({super.key, required this.dados, this.periodo = '24h'});
  final EventosSwitches dados;
  final String periodo;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final d = dados;
    final cards = [
      _cartao(t, 'Série', 'Eventos ao longo do tempo', 'Cada linha é um grupo de evento ao longo do período.',
          [GraficoLinha(pontos: d.serie, series: _grupos)]),
      _cartao(t, 'Grupos', 'Eventos por grupo', 'Como os eventos do período se dividem.', [
        GraficoPizza(
          fatias: [for (final g in _grupos) (rotuloCategoria[g]!, d.contagens[g] ?? 0)],
          centro: '${d.contagens.values.fold<int>(0, (a, b) => a + b)}',
        ),
      ]),
      _portas(t),
      _cartao(t, 'Clientes', 'Clientes que mais caem', 'Quem perdeu o link com mais frequência.', [
        GraficoBarras(dados: [for (final c in d.clientesTop) ('${c.cliente} · ${c.switchNome}', c.quedas)], cor: t.chart1),
        for (final c in d.clientesTop)
          Padding(
            padding: EdgeInsets.only(top: t.space3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.cliente, style: TradeType.label.copyWith(color: t.fgPrimary)),
              Text('IP ${c.ip ?? '—'} · MAC ${c.mac ?? '—'} · ${c.switchNome} porta ${c.porta ?? '—'}',
                  style: TradeType.bodySm.copyWith(color: t.fgSecondary)),
            ]),
          ),
      ]),
      for (final c in d.capacidade) _capacidade(t, c),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _indicadores(t),
      SizedBox(height: t.space4),
      _colunas(t, cards),
      _ultimosEventos(context, t),
    ]);
  }

  Widget _indicadores(TradeTokens t) {
    final o = dados.totais;
    // subir é ruim, cair é bom (mesma convenção do painel das MKs)
    (String?, Color) variacao(int? a, int? b) {
      final txt = textoVariacao(a, b);
      if (txt == null) return (null, t.fgMuted);
      return (txt, a == b ? t.fgSecondary : (a! > b! ? t.negative : t.positive));
    }

    final (vEv, cEv) = variacao(o.eventos, o.eventosAnterior);
    final (vQd, cQd) = variacao(o.quedasCliente, o.quedasClienteAnterior);
    final inst = o.portasInstaveis ?? 0;
    final itens = [
      Indicador(rotulo: 'Eventos', valor: '${o.eventos ?? 0}', dica: vEv, corDica: cEv),
      Indicador(rotulo: 'Quedas de cliente', valor: '${o.quedasCliente ?? 0}', dica: vQd, corDica: cQd),
      Indicador(
        rotulo: 'Portas instáveis',
        valor: '$inst',
        corValor: inst > 0 ? t.warning : null,
        dica: inst > 0 ? 'precisam de atenção' : 'nenhuma',
        corDica: inst > 0 ? t.warning : t.fgMuted,
      ),
      Indicador(
        rotulo: 'Projeção 30 dias',
        valor: o.projecao30d == null ? '—' : '${o.projecao30d}',
        dica: o.projecao30d == null ? null : 'eventos previstos',
      ),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 700 ? 4 : (c.maxWidth >= 380 ? 2 : 1);
      final w = (c.maxWidth - t.space4 * (cols - 1)) / cols;
      return Wrap(spacing: t.space4, runSpacing: t.space4, children: [for (final i in itens) SizedBox(width: w, child: i)]);
    });
  }

  /// 2 colunas a partir de 900 px, 1 abaixo; os cards ficam empilhados em cada coluna.
  Widget _colunas(TradeTokens t, List<Widget> itens) => LayoutBuilder(builder: (context, c) {
        Widget pilha(int ini, int passo) => Column(children: [
              for (var i = ini; i < itens.length; i += passo) Padding(padding: EdgeInsets.only(bottom: t.space4), child: itens[i]),
            ]);
        if (c.maxWidth < 900) return pilha(0, 1);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: pilha(0, 2)),
          SizedBox(width: t.space4),
          Expanded(child: pilha(1, 2)),
        ]);
      });

  Widget _cartao(TradeTokens t, String sobre, String titulo, String sub, List<Widget> filhos) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          eyebrow(sobre, cor: t.fgMuted),
          SizedBox(height: t.space1),
          Text(titulo, style: TradeType.heading3.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space1),
          Text(sub, style: TradeType.bodySm.copyWith(color: t.fgSecondary)),
          SizedBox(height: t.space4),
          ...filhos,
        ]),
      );

  Widget _portas(TradeTokens t) {
    final ps = dados.portasTop;
    final curto = periodo == '1h'; // 1 h é curto demais para projetar
    String nome(PortaTop p) => p.porta == null ? p.switchNome : '${p.switchNome} · Porta ${p.porta}';
    String chave(PortaTop p) => p.switchId ?? p.switchNome;
    final ids = {for (final p in ps) chave(p)}.toList();
    final switches = [for (final i in ids) ps.firstWhere((p) => chave(p) == i).switchNome];
    final cab = TradeType.label.copyWith(color: t.fgMuted);
    final cel = TradeType.bodyMd.copyWith(color: t.fgPrimary, fontFeatures: const [FontFeature.tabularFigures()]);
    return _cartao(t, 'Portas', 'Portas que mais oscilam', 'Portas com mais quedas e voltas de link no período.', [
      GraficoColunas(
        legenda: switches,
        dados: [
          for (final p in ps)
            ColunaDado(
              rotulo: 'P${p.porta ?? '?'}',
              valor: p.eventos,
              serie: ids.indexOf(chave(p)),
              destaque: p.instavel,
              dica: '${nome(p)}: ${p.eventos} eventos${p.projecaoMes == null ? '' : ' · ~${p.projecaoMes!.round()}/mês'}',
            ),
        ],
      ),
      SizedBox(height: t.space3),
      Text(
          'Projeção mensal: quantas vezes a porta deve oscilar em 30 dias se o ritmo deste período continuar. '
          'Instável = 3 ou mais eventos no período e projeção de 30 ou mais por mês.',
          style: TradeType.bodySm.copyWith(color: t.fgSecondary)),
      if (curto && ps.isNotEmpty)
        Text('período curto demais para projetar', style: TradeType.bodySm.copyWith(color: t.fgMuted)),
      if (ps.isNotEmpty) ...[
        SizedBox(height: t.space3),
        Table(
          columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(2), 2: FlexColumnWidth(2), 3: FlexColumnWidth(2)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(children: [
              Text('Porta', style: cab),
              Text('Eventos no período', style: cab),
              Text('Projeção 30 dias', style: cab),
              const SizedBox.shrink(),
            ]),
            for (final p in ps)
              TableRow(children: [
                Padding(padding: EdgeInsets.symmetric(vertical: t.space1), child: Text(nome(p), style: cel)),
                Text('${p.eventos}', style: cel),
                Text(curto || p.projecaoMes == null ? '—' : '${p.projecaoMes!.round()}', style: cel),
                Align(alignment: Alignment.centerLeft, child: p.instavel ? Selo('Instável', t.warning) : const SizedBox.shrink()),
              ]),
          ],
        ),
      ],
    ]);
  }

  Widget _capacidade(TradeTokens t, CapacidadeSwitch c) {
    final a = c.atual;
    final pr = c.projecoes;
    List<(DateTime, double)> serie(double? Function(PontoCapacidade) f) => [
          for (final p in c.historico)
            if (f(p) != null) (p.em, f(p)!),
        ];
    Widget sub(String rotulo, Widget g) => Padding(
          padding: EdgeInsets.only(top: t.space4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [eyebrow(rotulo, cor: t.fgMuted), SizedBox(height: t.space2), g]),
        );

    final emUso = a?.portasEmUso, total = a?.portasTotal;
    final poePortas = a?.poePorPorta ?? const <(String, double)>[];
    final tempSemana = pr.temperaturaTendenciaCSemana;
    return _cartao(t, 'Capacidade', 'Capacidade — ${c.switchNome}', 'Uso atual, histórico e para onde a tendência aponta.', [
      if (c.temPoe)
        sub('PoE (W)',
            GraficoCapacidade(pontos: serie((p) => p.poeW), limite: a?.poeMaxW, tendenciaDia: pr.poeTendenciaWDia, unidade: ' W', periodo: periodo)),
      sub('Clientes', GraficoCapacidade(pontos: serie((p) => p.clientes?.toDouble()), periodo: periodo)),
      sub('Temperatura (°C)',
          GraficoCapacidade(pontos: serie((p) => p.temperatura), tendenciaDia: tempSemana == null ? null : tempSemana / 7, unidade: ' °C', periodo: periodo)),
      if (emUso != null && total != null)
        sub('Portas', GraficoPizza(fatias: [('Em uso', emUso), ('Livres', (total - emUso).clamp(0, total))], centro: '$emUso/$total')),
      if (c.temPoe && poePortas.isNotEmpty)
        sub('PoE por porta', GraficoPizza(fatias: _fatiasPoe(poePortas, a?.poeMaxW), centro: '${(a?.poeUsadoW ?? 0).round()} W')),
      SizedBox(height: t.space4),
      ..._projecoes(t, pr),
    ]);
  }

  /// 5 maiores portas + "Outras" + "Livre" (capacidade que sobra).
  List<(String, num)> _fatiasPoe(List<(String, double)> portas, double? max) {
    final ord = [...portas]..sort((a, b) => b.$2.compareTo(a.$2));
    final outras = ord.skip(5).fold<double>(0, (s, p) => s + p.$2);
    final usado = ord.fold<double>(0, (s, p) => s + p.$2);
    return [
      for (final (p, w) in ord.take(5)) ('Porta $p', w),
      if (outras > 0) ('Outras', outras),
      if (max != null && max > usado) ('Livre', max - usado),
    ];
  }

  List<Widget> _projecoes(TradeTokens t, ProjecoesSwitch pr) {
    Widget linha(String texto, {Color? cor}) => Padding(
          padding: EdgeInsets.only(top: t.space1),
          child: Text(texto, style: TradeType.bodyMd.copyWith(color: cor ?? t.fgPrimary)),
        );
    if (pr.diasHistorico < _diasMinimos) {
      return [linha('Coletando histórico (${pr.diasHistorico} dias de $_diasMinimos)', cor: t.fgSecondary)];
    }
    final temp = pr.temperaturaTendenciaCSemana;
    return [
      if (pr.temPoe)
        pr.poeDiasAte80 == null ? linha('PoE estável') : linha('PoE chega a 80% em ~${pr.poeDiasAte80} dias', cor: t.warning),
      if (temp != null) linha('Temperatura ${temp >= 0 ? '+' : '−'}${temp.abs().toStringAsFixed(1).replaceAll('.', ',')} °C/semana'),
      pr.portasDiasAteCheio == null ? linha('Portas estáveis') : linha('Portas acabam em ~${pr.portasDiasAteCheio} dias', cor: t.warning),
    ];
  }

  Widget _ultimosEventos(BuildContext context, TradeTokens t) {
    final ev = dados.eventos;
    return TradeCard(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text('Últimos eventos', style: TradeType.heading3.copyWith(color: t.fgPrimary)),
          children: [
            if (ev.isEmpty) Text('Nenhum evento de switch no período.', style: TradeType.bodyMd.copyWith(color: t.fgMuted)),
            for (final e in ev) _linhaEvento(t, e),
          ],
        ),
      ),
    );
  }

  Widget _linhaEvento(TradeTokens t, EventoSwitch e) {
    final l = e.quando.toLocal();
    String dois(int v) => v.toString().padLeft(2, '0');
    final hora = '${dois(l.hour)}:${dois(l.minute)}';
    final agora = DateTime.now();
    final quando = l.year == agora.year && l.month == agora.month && l.day == agora.day ? hora : '${dois(l.day)}/${dois(l.month)} $hora';
    final (rotuloSev, cor) = switch (e.severidade) {
      'critical' => ('Crítico', t.negative),
      'high' => ('Alta', t.negative),
      'medium' => ('Média', t.warning),
      'low' => ('Baixa', t.fgSecondary),
      _ => (null, t.fgSecondary),
    };
    return Padding(
      padding: EdgeInsets.symmetric(vertical: t.space1),
      child: Wrap(spacing: t.space2, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(quando, style: TradeType.ticker.copyWith(color: t.fgMuted)),
        Text(e.porta == null ? e.switchNome : '${e.switchNome} · Porta ${e.porta}', style: TradeType.label.copyWith(color: t.fgPrimary)),
        if (rotuloSev != null) Selo(rotuloSev, cor),
        Text(e.mensagem, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
      ]),
    );
  }
}

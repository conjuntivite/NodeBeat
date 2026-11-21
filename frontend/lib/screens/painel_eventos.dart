import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/eventos.dart' show formatEventoHora;
import '../widgets/graficos.dart';
import '../widgets/painel_cards.dart';
import '../widgets/painel_textos.dart';

const _periodos = [('24 h', '24h'), ('7 dias', '7d'), ('30 dias', '30d')];
const _rotuloPeriodo = {'24h': 'últimas 24 h', '7d': 'últimos 7 dias', '30d': 'últimos 30 dias'};
const _categorias = ['acesso', 'autenticacao', 'vpn', 'erros'];

const _subtipos = {
  'falha_externa': 'Falha de login (internet)',
  'falha_interna': 'Falha de login (rede interna)',
  'login_ok': 'Login ok',
  'pppoe_auth': 'PPPoE: falha de autenticação',
  'falha': 'Falhas de VPN',
  'ok': 'Negociações ok',
  'link_fisico': 'Colisão / duplex',
  'interface_down': 'Interface caiu',
  'reboot': 'Reinício',
  'pppoe': 'PPPoE',
  'erro': 'Erro do sistema',
};

const _sintomas = {
  'interface_down': 'Interface caiu',
  'vpn_falha': 'Falha de VPN',
  'pppoe': 'Queda de PPPoE',
  'reboot': 'Reinício',
};

class PainelEventosScreen extends StatefulWidget {
  const PainelEventosScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<PainelEventosScreen> createState() => _PainelEventosScreenState();
}

class _PainelEventosScreenState extends State<PainelEventosScreen> {
  String _periodo = '24h';
  String? _mk;
  PainelEventos? _d;
  List<MkPainel> _mks = []; // lista completa, vinda da carga sem filtro
  String? _erro;
  int _pedido = 0;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final meu = ++_pedido;
    setState(() => _erro = null);
    try {
      final d = await widget.api.painelEventos(_periodo, mkId: _mk);
      if (!mounted || meu != _pedido) return;
      setState(() {
        _d = d;
        if (_mk == null) _mks = d.porMk;
      });
    } catch (e) {
      if (!mounted || meu != _pedido || sessionExpired(context, e)) return;
      setState(() => _erro = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final d = _d;
    return Scaffold(
      appBar: AppBar(
        leading: backFallback(context),
        backgroundColor: t.bgPage,
        actions: [const ThemeToggle(), SizedBox(width: t.space2)],
      ),
      body: ListView(padding: EdgeInsets.all(t.space6), children: [
        _cabecalho(t),
        SizedBox(height: t.space6),
        if (_erro != null) _falha(t) else if (d == null) const Center(child: CircularProgressIndicator()) else ..._conteudo(context, t, d),
      ]),
    );
  }

  Widget _cabecalho(TradeTokens t) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: t.space4,
        runSpacing: t.space4,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            eyebrow('NodeBeat · segurança e eventos', cor: t.fgMuted),
            SizedBox(height: t.space1),
            Text('Eventos', style: TradeType.heading1.copyWith(color: t.fgPrimary)),
            Text('O que as ${_mks.isEmpty ? '' : '${_mks.length} '}MKs registraram e o que merece sua atenção.',
                style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          ]),
          Wrap(spacing: t.space2, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _pilulasPeriodo(t),
            _filtroMk(t),
          ]),
        ],
      );

  Widget _pilulasPeriodo(TradeTokens t) => Container(
        padding: EdgeInsets.all(t.space1),
        decoration: BoxDecoration(
          color: t.bgSurface,
          borderRadius: BorderRadius.circular(t.radiusPill),
          border: Border.all(color: t.borderSubtle),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (rotulo, valor) in _periodos)
            InkWell(
              borderRadius: BorderRadius.circular(t.radiusPill),
              onTap: () {
                _periodo = valor;
                _carregar();
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: t.space3, vertical: t.space2),
                decoration: BoxDecoration(
                  color: valor == _periodo ? t.bgInverse : null,
                  borderRadius: BorderRadius.circular(t.radiusPill),
                ),
                child: Text(rotulo,
                    style: TradeType.label.copyWith(color: valor == _periodo ? t.fgInverse : t.fgSecondary)),
              ),
            ),
        ]),
      );

  Widget _filtroMk(TradeTokens t) => Container(
        padding: EdgeInsets.symmetric(horizontal: t.space4),
        decoration: BoxDecoration(
          color: t.bgSurface,
          borderRadius: BorderRadius.circular(t.radiusPill),
          border: Border.all(color: t.borderSubtle),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: _mk,
            borderRadius: BorderRadius.circular(t.radiusMd),
            style: TradeType.label.copyWith(color: t.fgPrimary),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('Todas as MKs')),
              for (final m in _mks) DropdownMenuItem<String?>(value: m.mkId, child: Text(m.nome)),
            ],
            onChanged: (v) {
              _mk = v;
              _carregar();
            },
          ),
        ),
      );

  Widget _falha(TradeTokens t) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_erro!, style: TradeType.bodyMd.copyWith(color: t.negative)),
          SizedBox(height: t.space3),
          OutlinedButton(onPressed: _carregar, child: const Text('Tentar de novo')),
        ]),
      );

  List<Widget> _conteudo(BuildContext context, TradeTokens t, PainelEventos d) => [
        _topo(context, t, d),
        if (d.incidentes.isNotEmpty) ...[SizedBox(height: t.space4), _incidentes(t, d)],
        SizedBox(height: t.space4),
        _resumo(t, d),
        SizedBox(height: t.space4),
        _bloco(t, 'Acesso (hacker)', d.blocos['acesso'], 'acesso', [
          _lista(t, 'IPs que mais tentaram', [for (final i in d.blocos['acesso']?.topIps ?? const <ContaIp>[]) (i.ip, '${i.n}')]),
          _barras(t, 'Serviços atacados', [for (final e in (d.blocos['acesso']?.porVia ?? const <String, int>{}).entries) (e.key, e.value)]),
          _lista(t, 'Logins de fora', [
            for (final l in d.blocos['acesso']?.loginsExternos ?? const <Map<String, dynamic>>[])
              ('${l['usuario']} de ${l['ip']} via ${l['via']}', '${l['nome']}'),
          ], cor: t.negative),
        ]),
        SizedBox(height: t.space4),
        _bloco(t, 'Autenticação', d.blocos['autenticacao'], 'autenticacao', [_subtiposBarras(t, d.blocos['autenticacao'])]),
        SizedBox(height: t.space4),
        _bloco(t, 'VPN', d.blocos['vpn'], 'vpn', [
          _subtiposBarras(t, d.blocos['vpn']),
          _lista(t, 'Últimas falhas', [
            for (final u in d.blocos['vpn']?.ultimos ?? const <Map<String, dynamic>>[])
              ('${u['nome']}: ${u['mensagem']}', formatEventoHora(DateTime.parse(u['quando']))),
          ]),
        ]),
        SizedBox(height: t.space4),
        _bloco(t, 'Erros importantes', d.blocos['erros'], 'erros', [
          _subtiposBarras(t, d.blocos['erros']),
          _lista(t, 'Colisão / duplex por interface', [
            for (final i in d.blocos['erros']?.interfaces ?? const <Map<String, dynamic>>[]) ('${i['nome']} · ${i['interface']}', '${i['n']}'),
          ]),
        ]),
        SizedBox(height: t.space4),
        _config(t, d),
      ];

  Widget _topo(BuildContext context, TradeTokens t, PainelEventos d) {
    int n(String c) => d.porMk.where((m) => m.semaforo == c).length;
    final situacao = CartaoSituacao(
      frase: fraseSituacao(d),
      eyebrowTexto: 'Situação · ${_rotuloPeriodo[d.periodo] ?? d.periodo}',
      verdes: n('verde'),
      amarelas: n('amarelo'),
      vermelhas: n('vermelho'),
    );
    final atencao = PainelAtencao(itens: d.atencao, aoAbrir: (id) => Navigator.of(context).pushNamed('/mk/$id'));
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 900) {
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 3, child: situacao),
            SizedBox(width: t.space4),
            Expanded(flex: 2, child: atencao),
          ]),
        );
      }
      return Column(children: [situacao, SizedBox(height: t.space4), atencao]);
    });
  }

  Widget _incidentes(TradeTokens t, PainelEventos d) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Incidentes entre MKs', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          Text('Várias MKs com o mesmo problema ao mesmo tempo: provável causa na sede ou na operadora.',
              style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          SizedBox(height: t.space3),
          for (final i in d.incidentes)
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Text('${formatEventoHora(i.inicio)} · ${_sintomas[i.sintoma] ?? i.sintoma} · ${i.mks.join(', ')}',
                  style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
            ),
        ]),
      );

  Widget _resumo(TradeTokens t, PainelEventos d) {
    final porMk = [
      for (final m in d.porMk)
        (m.nome, m.contagens.values.fold<int>(0, (a, b) => a + b)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    Widget cartao(String titulo, Widget grafico) => TradeCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo, style: TradeType.heading4.copyWith(color: t.fgPrimary)),
            SizedBox(height: t.space3),
            grafico,
          ]),
        );
    return LayoutBuilder(builder: (context, c) {
      final pizza = cartao('Por categoria', GraficoPizza(dados: {for (final k in _categorias) k: d.resumo[k] ?? 0}));
      final barras = cartao('Por MK', GraficoBarras(dados: porMk.where((e) => e.$2 > 0).take(10).toList()));
      final linha = cartao('Ao longo do tempo', GraficoLinha(pontos: d.serieHora, series: _categorias));
      if (c.maxWidth >= 900) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: pizza),
          SizedBox(width: t.space4),
          Expanded(child: barras),
          SizedBox(width: t.space4),
          Expanded(flex: 2, child: linha),
        ]);
      }
      return Column(children: [pizza, SizedBox(height: t.space4), barras, SizedBox(height: t.space4), linha]);
    });
  }

  Widget _bloco(TradeTokens t, String titulo, BlocoPainel? b, String cat, List<Widget> filhos) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(titulo, style: TradeType.heading4.copyWith(color: t.fgPrimary))),
            Text('${b?.total ?? 0}', key: Key('total-$cat'), style: TradeType.dataLg.copyWith(color: corCategoria(t, cat))),
          ]),
          SizedBox(height: t.space3),
          _barras(t, 'Por MK', [for (final m in b?.porMk ?? const <ContaMk>[]) (m.nome, m.n)]),
          ...filhos,
        ]),
      );

  Widget _barras(TradeTokens t, String titulo, List<(String, int)> dados) => dados.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.only(top: t.space3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo, style: TradeType.label.copyWith(color: t.fgSecondary)),
            SizedBox(height: t.space1),
            GraficoBarras(dados: dados),
          ]),
        );

  Widget _subtiposBarras(TradeTokens t, BlocoPainel? b) =>
      _barras(t, 'Tipos', [for (final e in (b?.porSubtipo ?? const <String, int>{}).entries) (_subtipos[e.key] ?? e.key, e.value)]);

  Widget _lista(TradeTokens t, String titulo, List<(String, String)> itens, {Color? cor}) => itens.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.only(top: t.space3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo, style: TradeType.label.copyWith(color: t.fgSecondary)),
            for (final (a, b) in itens)
              Padding(
                padding: EdgeInsets.symmetric(vertical: t.space1),
                child: Row(children: [
                  Expanded(child: Text(a, style: dataStyle(context, TradeType.dataSm).copyWith(color: cor ?? t.fgPrimary))),
                  Text(b, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
                ]),
              ),
          ]),
        );

  Widget _selinho(TradeTokens t, String texto, Color cor) => Container(
        margin: EdgeInsets.only(left: t.space2),
        padding: EdgeInsets.symmetric(horizontal: t.space2, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: cor), borderRadius: BorderRadius.circular(t.radiusPill)),
        child: Text(texto, style: TradeType.label.copyWith(color: cor)),
      );

  Widget _config(TradeTokens t, PainelEventos d) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Mudanças de configuração', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space3),
          if (d.config.isEmpty) Text('Nenhuma mudança no período', style: TradeType.bodyMd.copyWith(color: t.fgMuted)),
          for (final c in d.config.take(50))
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${formatEventoHora(c.quando)} · ${c.nome} · ${c.usuario ?? '?'} · ${c.acao ?? ''} ${c.objeto ?? ''}',
                    style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
                if (c.foraHorario) _selinho(t, 'fora do horário', t.warning),
                if (c.usuarioNovo) _selinho(t, 'usuário novo', t.warning),
              ]),
            ),
        ]),
      );
}

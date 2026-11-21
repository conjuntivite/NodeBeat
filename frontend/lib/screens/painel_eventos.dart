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
  final _chaves = {for (final c in _categorias) c: GlobalKey()};

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

  List<Widget> _conteudo(BuildContext context, TradeTokens t, PainelEventos d) {
    final porMk = [
      for (final m in d.porMk) (m.nome, m.contagens.values.fold<int>(0, (a, b) => a + b)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final ranking = porMk.where((e) => e.$2 > 0).take(10).toList();
    final nota = notaConcentracao(ranking);
    final blocoAcesso = d.blocos['acesso'];
    final logins = blocoAcesso?.loginsExternos ?? const <Map<String, dynamic>>[];

    final cards = [
      for (final c in _categorias)
        CartaoCategoria(
          categoria: c,
          total: d.resumo[c] ?? 0,
          estado: d.resumoEstado[c],
          serie: d.serieHora,
          aoVerDetalhes: () {
            final ctx = _chaves[c]!.currentContext;
            if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.05);
          },
        ),
    ];

    final linha = _cartao(t, 'Ao longo do tempo', 'Quando os eventos aconteceram',
        'Cada linha é um tipo de evento por hora. Picos isolados costumam ser varredura; subida contínua merece atenção.', [
      GraficoLinha(pontos: d.serieHora, series: _categorias),
    ]);
    final barras = _cartao(t, 'Por MK', 'Quem mais recebe eventos',
        'Mais eventos não quer dizer mais problema: MKs com IP público exposto recebem mais varredura.', [
      GraficoBarras(dados: ranking, cor: t.bgBrand),
      if (nota != null) _aviso(t, nota),
    ]);

    return [
      _topo(context, t, d),
      SizedBox(height: t.space4),
      _grade(t, cards, [1000, 560]),
      SizedBox(height: t.space4),
      LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 900) return Column(children: [linha, SizedBox(height: t.space4), barras]);
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 2, child: linha),
            SizedBox(width: t.space4),
            Expanded(child: barras),
          ]),
        );
      }),
      SizedBox(height: t.space4),
      _detalheAcesso(t, blocoAcesso, logins),
      SizedBox(height: t.space4),
      _grade(t, [
        _detalhe(t, 'autenticacao', 'Quem erra a senha por dentro', 'Falhas de login na rede interna e de PPPoE, por tipo e por MK.',
            d.blocos['autenticacao'], [_subtiposBarras(t, d.blocos['autenticacao'])]),
        _detalhe(t, 'vpn', 'Túneis com falha', 'Falhas ao negociar o túnel, por MK e as últimas ocorrências.', d.blocos['vpn'], [
          _subtiposBarras(t, d.blocos['vpn']),
          _lista(t, 'Últimas falhas', [
            for (final u in d.blocos['vpn']?.ultimos ?? const <Map<String, dynamic>>[])
              ('${u['nome']}: ${u['mensagem']}', formatEventoHora(DateTime.parse(u['quando']))),
          ]),
        ]),
        _detalhe(t, 'erros', 'Problemas nas MKs e no cabo', 'Reinícios, quedas de interface e colisões, por tipo e por MK.',
            d.blocos['erros'], [
          _subtiposBarras(t, d.blocos['erros']),
          _lista(t, 'Colisão / duplex por interface', [
            for (final i in d.blocos['erros']?.interfaces ?? const <Map<String, dynamic>>[]) ('${i['nome']} · ${i['interface']}', '${i['n']}'),
          ]),
        ]),
      ], [1000, 700]),
      if (d.incidentes.isNotEmpty) ...[SizedBox(height: t.space4), _incidentes(t, d)],
      SizedBox(height: t.space4),
      _config(t, d),
    ];
  }

  /// Distribui os cards em colunas: a partir do 1.º limite todos lado a lado; a partir do 2.º, 2 colunas; abaixo, uma.
  Widget _grade(TradeTokens t, List<Widget> itens, List<double> limites) => LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth >= limites[0] ? itens.length : (c.maxWidth >= limites[1] ? 2 : 1);
        final linhas = <Widget>[];
        for (var i = 0; i < itens.length; i += cols) {
          final grupo = itens.sublist(i, i + cols > itens.length ? itens.length : i + cols);
          if (linhas.isNotEmpty) linhas.add(SizedBox(height: t.space4));
          linhas.add(IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var k = 0; k < cols; k++) ...[
                if (k > 0) SizedBox(width: t.space4),
                Expanded(child: k < grupo.length ? grupo[k] : const SizedBox.shrink()),
              ],
            ]),
          ));
        }
        return Column(children: linhas);
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

  Widget _aviso(TradeTokens t, String texto) => Container(
        margin: EdgeInsets.only(top: t.space4),
        padding: EdgeInsets.all(t.space3),
        decoration: BoxDecoration(color: t.info.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(t.radiusMd)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 16, color: t.info),
          SizedBox(width: t.space2),
          Expanded(child: Text(texto, style: TradeType.bodySm.copyWith(color: t.fgPrimary))),
        ]),
      );

  Widget _detalheAcesso(TradeTokens t, BlocoPainel? b, List<Map<String, dynamic>> logins) => Container(
        key: _chaves['acesso'],
        child: TradeCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(alignment: WrapAlignment.spaceBetween, spacing: t.space3, runSpacing: t.space3, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  eyebrow('Acesso · detalhe', cor: t.fgMuted),
                  SizedBox(height: t.space1),
                  Text('Quem está tentando entrar', style: TradeType.heading3.copyWith(color: t.fgPrimary)),
                  SizedBox(height: t.space1),
                  Text('IPs da internet que erraram a senha. Um IP que aparece muito dá para bloquear no firewall.',
                      style: TradeType.bodySm.copyWith(color: t.fgSecondary)),
                ]),
              ),
              logins.isEmpty
                  ? Pilula('Nenhum login de fora aceito', cor: t.positive)
                  : Pilula(logins.length == 1 ? '1 login de fora aceito' : '${logins.length} logins de fora aceitos', cor: t.negative),
            ]),
            SizedBox(height: t.space4),
            LayoutBuilder(builder: (context, c) {
              final ips = _lista(t, 'IPs que mais tentaram', [for (final i in b?.topIps ?? const <ContaIp>[]) (i.ip, '${i.n} tentativas')],
                  pilulaCor: t.negative);
              final vias = _barras(t, 'Serviço atacado', [for (final e in (b?.porVia ?? const <String, int>{}).entries) (e.key.toUpperCase(), e.value)]);
              final dois = c.maxWidth >= 700;
              return dois
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: ips),
                      SizedBox(width: t.space6),
                      Expanded(child: vias),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ips, vias]);
            }),
            _lista(t, 'Logins de fora aceitos', [
              for (final l in logins) ('${l['usuario']} de ${l['ip']} via ${l['via']}', '${l['nome']}'),
            ], cor: t.negative),
          ]),
        ),
      );

  Widget _detalhe(TradeTokens t, String cat, String titulo, String sub, BlocoPainel? b, List<Widget> filhos) => Container(
        key: _chaves[cat],
        child: _cartao(t, rotuloCategoria[cat] ?? cat, titulo, sub, [
          _barras(t, 'Por MK', [for (final m in b?.porMk ?? const <ContaMk>[]) (m.nome, m.n)], topo: false),
          ...filhos,
        ]),
      );

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

  Widget _incidentes(TradeTokens t, PainelEventos d) => _cartao(
        t,
        'Correlação',
        'Incidentes entre MKs',
        'Várias MKs com o mesmo problema ao mesmo tempo: provável causa na sede ou na operadora.',
        [
          for (final i in d.incidentes)
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Text('${formatEventoHora(i.inicio)} · ${_sintomas[i.sintoma] ?? i.sintoma} · ${i.mks.join(', ')}',
                  style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
            ),
        ],
      );

  Widget _barras(TradeTokens t, String titulo, List<(String, int)> dados, {bool topo = true}) => dados.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.only(top: topo ? t.space3 : 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            eyebrow(titulo, cor: t.fgMuted),
            SizedBox(height: t.space2),
            GraficoBarras(dados: dados, cor: t.bgBrand),
          ]),
        );

  Widget _subtiposBarras(TradeTokens t, BlocoPainel? b) =>
      _barras(t, 'Tipos', [for (final e in (b?.porSubtipo ?? const <String, int>{}).entries) (_subtipos[e.key] ?? e.key, e.value)]);

  Widget _lista(TradeTokens t, String titulo, List<(String, String)> itens, {Color? cor, Color? pilulaCor}) => itens.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.only(top: t.space3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            eyebrow(titulo, cor: t.fgMuted),
            SizedBox(height: t.space2),
            for (final (a, b) in itens)
              Padding(
                padding: EdgeInsets.symmetric(vertical: t.space1),
                child: Row(children: [
                  Expanded(child: Text(a, style: dataStyle(context, TradeType.dataSm).copyWith(color: cor ?? t.fgPrimary))),
                  SizedBox(width: t.space2),
                  if (pilulaCor != null) Pilula(b, cor: pilulaCor) else Text(b, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
                ]),
              ),
          ]),
        );

  Widget _config(TradeTokens t, PainelEventos d) => _cartao(
        t,
        'Auditoria',
        'Mudanças de configuração',
        'Quem mexeu na configuração das MKs. "Fora do horário" e "usuário novo" merecem conferência.',
        [
          if (d.config.isEmpty) Text('Nenhuma mudança no período', style: TradeType.bodyMd.copyWith(color: t.fgMuted)),
          for (final c in d.config.take(50))
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Wrap(spacing: t.space2, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(formatEventoHora(c.quando), style: TradeType.ticker.copyWith(color: t.fgMuted)),
                Text('${c.nome} · ${c.usuario ?? '?'} · ${c.acao ?? ''} ${c.objeto ?? ''}',
                    style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
                if (c.foraHorario) Pilula('fora do horário', cor: t.warning),
                if (c.usuarioNovo) Pilula('usuário novo', cor: t.warning),
              ]),
            ),
        ],
      );
}

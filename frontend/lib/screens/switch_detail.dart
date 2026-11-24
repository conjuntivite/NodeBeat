import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/eventos.dart';
import '../widgets/painel_portas.dart';
import '../widgets/shell.dart';

/// Velocidade em Mbps: 1000 -> "1 Gbps", 100 -> "100 Mbps".
String velocidadeTxt(int mbps) => mbps >= 1000 ? '${mbps % 1000 == 0 ? mbps ~/ 1000 : mbps / 1000} Gbps' : '$mbps Mbps';

/// Decimal com vírgula e 1 casa: 2.5 -> "2,5"; null -> "—".
String _dec(double? v) => v == null ? '—' : v.toStringAsFixed(1).replaceAll('.', ',');

/// Inteiro sem casas: 16.0 -> "16".
String _int(double v) => v.round().toString();

/// Detalhe de um switch: indicadores, painel frontal, tabela de portas, histórico e syslog.
class SwitchDetailScreen extends StatefulWidget {
  const SwitchDetailScreen(this.api, this.id, {super.key});
  final ApiClient api;
  final String id;

  @override
  State<SwitchDetailScreen> createState() => _SwitchDetailScreenState();
}

class _SwitchDetailScreenState extends State<SwitchDetailScreen> {
  Equipamento? _eq;
  List<HistEvent> _hist = const [];
  List<dynamic> _eventos = const [];
  PortaVista? _porta;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final eq = await widget.api.equipamento(widget.id);
      final hist = await widget.api.historicoEquipamento(widget.id);
      final ev = await widget.api.eventosEquipamento(widget.id);
      if (!mounted) return;
      setState(() {
        _eq = eq;
        _hist = hist;
        _eventos = ev;
        _error = null;
      });
    } catch (e) {
      if (mounted && !sessionExpired(context, e)) setState(() => _error = errorText(e));
    }
  }

  void _erro(Object e) {
    if (!mounted || sessionExpired(context, e)) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
  }

  Future<void> _renomear() async {
    final ctrl = TextEditingController(text: _eq!.nome);
    final nome = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Renomear switch'),
        content: SizedBox(width: 360, child: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Nome'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Salvar')),
        ],
      ),
    );
    if (nome == null || nome.isEmpty) return;
    try {
      await widget.api.atualizarEquipamento(widget.id, nome: nome);
      await _load();
    } catch (e) {
      _erro(e);
    }
  }

  Future<void> _apagar() async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Apagar ${_eq!.nome}?'),
            content: const Text('O switch e o histórico dele saem do monitoramento.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apagar')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await widget.api.apagarEquipamento(widget.id);
      if (mounted) Navigator.of(context).pushNamedAndRemoveUntil('/painel', (_) => false);
    } catch (e) {
      _erro(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final eq = _eq;
    final status = '${eq?.estado?['status'] ?? 'desconhecido'}';
    final cor = status == 'no_ar' ? t.positive : (status == 'offline' || status == 'erro_acesso') ? t.negative : t.fgSecondary;
    final rotulo = switch (status) { 'no_ar' => 'No ar', 'offline' => 'Offline', 'erro_acesso' => 'Erro de acesso', _ => 'Aguardando' };
    final rel = relativo(eq?.estado?['desde']);
    return AppShell(
      ativo: 'switch',
      titulo: eq?.nome ?? 'Switch',
      subtitulo: eq == null
          ? null
          : [
              eq.ip,
              eq.localNome ?? 'Sem local',
              if (eq.estado?['detalhe'] != null) '${eq.estado!['detalhe']}',
              if (eq.unifi?.firmware != null) 'Firmware ${eq.unifi!.firmware}${eq.unifi!.atualizacao ? ' · atualização disponível' : ''}',
            ].join(' · '),
      migalhas: Migalhas(anterior: 'Switches', atual: eq?.nome ?? 'Switch', aoVoltar: () => voltar(context)),
      acoes: eq == null
          ? const []
          : [
              Padding(
                padding: EdgeInsets.only(top: t.space2),
                child: Selo(rel.isEmpty ? rotulo : '$rotulo · $rel', cor, ponto: true),
              ),
              OutlinedButton(onPressed: _renomear, child: const Text('Renomear')),
              if (eq.origem == 'manual')
                OutlinedButton(
                  onPressed: _apagar,
                  style: OutlinedButton.styleFrom(
                      backgroundColor: t.negativeBg, foregroundColor: t.negative, side: BorderSide(color: t.negative)),
                  child: const Text('Apagar'),
                ),
            ],
      body: eq == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: TradeType.bodyMd.copyWith(color: t.negative)))
          : ListView(padding: margemPagina(context), children: [
              _indicadores(t, eq),
              SizedBox(height: t.space4),
              TradeCard(
                titulo: 'Painel frontal',
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  PainelPortas(portas: eq.portas, aoTocar: (p) => setState(() => _porta = p)),
                  if (_porta != null) ...[SizedBox(height: t.space4), _detalhePorta(t, eq, _porta!)],
                ]),
              ),
              SizedBox(height: t.space4),
              _tabelaPortas(t, eq),
              SizedBox(height: t.space4),
              _historico(t),
              SizedBox(height: t.space4),
              _syslog(t),
            ]),
    );
  }

  Widget _indicadores(TradeTokens t, Equipamento eq) {
    final up = eq.portas.where((p) => p.estado == 'up').length;
    final caiu = eq.portas.where((p) => p.estado == 'caiu').length;
    final rapidas = eq.portas.where((p) => p.estado == 'up' && (p.velocidade ?? 0) >= 1000).length;
    final u = eq.unifi;
    return Wrap(spacing: t.space4, runSpacing: t.space4, children: [
      Indicador(rotulo: 'Portas', valor: '${eq.portas.length}'),
      Indicador(rotulo: 'Com link', valor: '$up', dica: '$rapidas a 1 Gbps ou mais'),
      Indicador(
        rotulo: 'Sem link',
        valor: '${eq.portas.length - up}',
        dica: switch (caiu) { 0 => 'nenhuma caiu nas últimas 24 h', 1 => '1 caiu nas últimas 24 h', _ => '$caiu caíram nas últimas 24 h' },
        corDica: caiu == 0 ? null : t.negative,
      ),
      Indicador(rotulo: 'Uplinks', valor: '${eq.uplinks.length}', dica: 'levam a outro switch'),
      if (u != null) ...[
        if (u.cpu != null) Indicador(rotulo: 'CPU', valor: '${_int(u.cpu!)}%'),
        if (u.mem != null) Indicador(rotulo: 'Memória', valor: '${_int(u.mem!)}%'),
        if (u.temperatura != null) Indicador(rotulo: 'Temperatura', valor: '${_int(u.temperatura!)} °C'),
        if (u.poeUsadoW != null)
          Indicador(rotulo: 'PoE', valor: '${_dec(u.poeUsadoW)} W', dica: u.poeMaxW == null ? null : 'de ${_int(u.poeMaxW!)} W'),
        if (u.uptimeS != null) Indicador(rotulo: 'Uptime', valor: formatDuration(u.uptimeS!)),
        if (u.clientes != null) Indicador(rotulo: 'Clientes', valor: '${u.clientes}'),
      ],
    ]);
  }

  /// Clientes da lista (mesmo número do detalhe); sem lista, os aparelhos vistos na porta.
  int _nClientes(UnifiPorta? u) => u == null ? 0 : u.clientes.isNotEmpty ? u.clientes.length : u.aparelhos;

  /// "10,0 / 0,4 Mbps" (↓ / ↑); "—" sem dado.
  String _trafego(UnifiPorta? u) => u == null || (u.rxMbps == null && u.txMbps == null) ? '—' : '${_dec(u.rxMbps)} / ${_dec(u.txMbps)} Mbps';

  String _estadoTxt(String e) => switch (e) { 'up' => 'Com link', 'caiu' => 'Caiu', _ => 'Sem link' };

  String? _ligado(Equipamento eq, String porta) {
    final u = eq.uplinks[porta] as Map?;
    return u == null ? null : (u['filho'] != null ? 'switch ${u['filho']}' : '${u['vigiados'] ?? 0} aparelhos vigiados');
  }

  /// Tabela de portas (DataTable): cabeçalho em surface-200, linha selecionada em brand-tint.
  Widget _tabelaPortas(TradeTokens t, Equipamento eq) {
    final head = TradeType.label.copyWith(color: t.fgSecondary);
    final cel = TradeType.bodyMd.copyWith(color: t.fgPrimary);
    const flex = [2, 3, 2, 2, 4, 2, 3, 2, 2, 2];
    UnifiPorta? un(PortaVista p) => eq.unifi?.portas[p.nome];
    Widget linha(List<Widget> c, {Color? fundo, VoidCallback? onTap, Key? key}) => InkWell(
          key: key,
          onTap: onTap,
          hoverColor: t.bgHover,
          child: Container(
            padding: EdgeInsets.symmetric(vertical: t.space2, horizontal: t.space3),
            decoration: BoxDecoration(color: fundo, border: Border(bottom: BorderSide(color: t.borderSubtle))),
            child: Row(children: [for (var i = 0; i < c.length; i++) Expanded(flex: flex[i], child: c[i])]),
          ),
        );
    return TradeCard(
      titulo: 'Portas',
      child: LayoutBuilder(
        builder: (_, box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: box.maxWidth < 900 ? 900 : box.maxWidth,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(t.radiusMd), border: Border.all(color: t.borderSubtle)),
              child: Column(children: [
                linha([for (final h in ['Porta', 'Estado', 'Velocidade', 'Há quanto tempo', 'Ligado a', 'PoE', '↓ / ↑', 'Erros', 'STP', 'Clientes']) Text(h, style: head)],
                    fundo: t.bgSubtle),
                for (final p in eq.portas)
                  linha(
                    key: Key('linha-porta-${p.nome}'),
                    fundo: _porta?.nome == p.nome ? t.brandTint : null,
                    onTap: () => setState(() => _porta = p),
                    [
                      Text(p.nome, style: TradeType.ticker.copyWith(color: t.fgPrimary)),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Selo(_estadoTxt(p.estado), p.estado == 'up' ? t.positive : p.estado == 'caiu' ? t.negative : t.fgSecondary),
                      ),
                      Text(p.estado == 'up' && p.velocidade != null ? velocidadeTxt(p.velocidade!) : '—',
                          style: cel.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                      Text(relativo(p.desde).isEmpty ? '—' : relativo(p.desde), style: cel),
                      Text(_ligado(eq, p.nome) ?? '—', overflow: TextOverflow.ellipsis, style: cel),
                      Text(un(p)?.poeW == null ? '—' : '${_dec(un(p)!.poeW)} W', style: cel),
                      Text(_trafego(un(p)), overflow: TextOverflow.ellipsis, style: cel),
                      Text(un(p)?.erros == null ? '—' : '${un(p)!.erros}', style: cel),
                      Text(un(p)?.stp ?? '—', overflow: TextOverflow.ellipsis, style: cel),
                      Text(_nClientes(un(p)) == 0 ? '—' : '${_nClientes(un(p))}', style: cel),
                    ],
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detalhePorta(TradeTokens t, Equipamento eq, PortaVista p) {
    final up = p.estado == 'up';
    final rel = relativo(p.desde);
    final ligado = _ligado(eq, p.nome);
    final un = eq.unifi?.portas[p.nome];
    final uplink = eq.unifi != null && eq.unifi!.ehUplink(p.nome) ? eq.unifi!.uplink : null;
    Widget linha(String k, String v) => Padding(
          padding: EdgeInsets.symmetric(vertical: t.space1),
          child: Row(children: [
            SizedBox(width: 120, child: Text(k, style: TradeType.label.copyWith(color: t.fgSecondary))),
            Expanded(child: Text(v, style: TradeType.bodyMd.copyWith(color: t.fgPrimary))),
          ]),
        );
    return Container(
      key: const Key('detalhe-porta'),
      padding: EdgeInsets.all(t.space4),
      decoration: BoxDecoration(color: t.bgSubtle, borderRadius: BorderRadius.circular(t.radiusMd)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Porta ${p.nome}', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space2),
        linha('Estado', _estadoTxt(p.estado)),
        if (up && p.velocidade != null) linha('Velocidade', velocidadeTxt(p.velocidade!)),
        if (rel.isNotEmpty) linha(up ? 'Com link' : 'Sem link', 'há $rel'),
        if (ligado != null) linha('Ligado a', ligado),
        if (un != null) ...[
          if (un.poeW != null) linha('PoE', '${_dec(un.poeW)} W'),
          if (_trafego(un) != '—') linha('↓ / ↑', _trafego(un)),
        ],
        if (uplink != null)
          linha('Uplink', 'para ${uplink['remoto'] ?? 'outro switch'}${uplink['remoto_porta'] != null ? ' (porta ${uplink['remoto_porta']})' : ''}'),
        if (un != null && un.clientes.isNotEmpty) ..._clientes(t, un.clientes),
      ]),
    );
  }

  List<Widget> _clientes(TradeTokens t, List<UnifiCliente> cs) {
    Widget cli(UnifiCliente c) => Padding(
          padding: EdgeInsets.symmetric(vertical: t.space1),
          child: Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(c.nome ?? c.fabricante ?? 'Sem nome', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
            Text([if (c.ip != null) c.ip!, if (c.mac != null) c.mac!].join(' · '), style: TradeType.ticker.copyWith(color: t.fgSecondary)),
            if (c.mbps != null) Text(velocidadeTxt(c.mbps!.round()), style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          ]),
        );
    return [
      SizedBox(height: t.space3),
      Text('Equipamentos nesta porta (${cs.length})', style: TradeType.label.copyWith(color: t.fgSecondary)),
      if (cs.length > 8)
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320), child: ListView(shrinkWrap: true, children: [for (final c in cs) cli(c)]))
      else
        for (final c in cs) cli(c),
    ];
  }

  Widget _historico(TradeTokens t) => TradeCard(
        titulo: 'Histórico',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_hist.isEmpty) Text('Sem eventos.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          for (final h in _hist)
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Text(
                [
                  statusLabel(h.tipo, false),
                  h.evento == 'queda' ? 'Queda' : h.evento == 'retorno' ? 'Retorno' : h.evento,
                  if (h.detalhe != null) h.detalhe!,
                  formatDateTime(h.fim ?? h.inicio),
                  if (h.duracaoS != null) formatDuration(h.duracaoS!),
                ].where((x) => x.isNotEmpty).join(' · '),
                style: TradeType.bodyMd.copyWith(color: t.fgPrimary),
              ),
            ),
        ]),
      );

  Widget _syslog(TradeTokens t) => TradeCard(
        titulo: 'Eventos do syslog',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_eventos.isEmpty) Text('Sem eventos.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          for (final e in _eventos.map((j) => Evento.fromJson(j as Map<String, dynamic>)))
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Text('${formatEventoHora(e.recebidoEm)} · ${e.mensagem}', style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
            ),
        ]),
      );
}

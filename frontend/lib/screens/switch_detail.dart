import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/eventos.dart';
import '../widgets/painel_portas.dart';

/// Velocidade em Mbps: 1000 -> "1 Gbps", 100 -> "100 Mbps".
String velocidadeTxt(int mbps) => mbps >= 1000 ? '${mbps % 1000 == 0 ? mbps ~/ 1000 : mbps / 1000} Gbps' : '$mbps Mbps';

/// Detalhe de um switch: desenho das portas, porta tocada, histórico e eventos do syslog.
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
    return Scaffold(
      appBar: AppBar(
        leading: backFallback(context),
        backgroundColor: t.bgPage,
        title: Text(eq?.nome ?? 'Switch', style: TradeType.heading3.copyWith(color: t.fgPrimary)),
        actions: [const ThemeToggle(), SizedBox(width: t.space2)],
      ),
      body: eq == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: TradeType.bodyMd.copyWith(color: t.negative)))
          : ListView(padding: EdgeInsets.all(t.space6), children: [
              _cabecalho(t, eq),
              SizedBox(height: t.space4),
              PainelPortas(portas: eq.portas, aoTocar: (p) => setState(() => _porta = p)),
              SizedBox(height: t.space4),
              if (_porta != null) ...[_detalhePorta(t, eq, _porta!), SizedBox(height: t.space4)],
              _historico(t),
              SizedBox(height: t.space4),
              _syslog(t),
            ]),
    );
  }

  Widget _cabecalho(TradeTokens t, Equipamento eq) {
    final status = '${eq.estado?['status'] ?? 'desconhecido'}';
    final cor = status == 'no_ar' ? t.positive : (status == 'offline' || status == 'erro_acesso') ? t.negative : t.fgSecondary;
    final rotulo = switch (status) { 'no_ar' => 'No ar', 'offline' => 'Offline', 'erro_acesso' => 'Erro de acesso', _ => 'Aguardando' };
    final rel = relativo(eq.estado?['desde']);
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: t.space4, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(eq.nome, style: TradeType.heading3.copyWith(color: t.fgPrimary)),
          Text(eq.localNome ?? 'Sem local', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(color: cor, shape: BoxShape.circle)),
            SizedBox(width: t.space2),
            Text(rotulo, style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
          ]),
          Text(eq.ip, style: dataStyle(context, TradeType.dataSm)),
          if (rel.isNotEmpty) Text('há $rel', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        ]),
        if (eq.estado?['detalhe'] != null)
          Padding(
              padding: EdgeInsets.only(top: t.space3),
              child: Text('${eq.estado!['detalhe']}', style: TradeType.bodyMd.copyWith(color: t.fgSecondary))),
        SizedBox(height: t.space4),
        Wrap(spacing: t.space2, runSpacing: t.space2, children: [
          OutlinedButton(onPressed: _renomear, child: const Text('Renomear')),
          if (eq.origem == 'manual')
            FilledButton(
                onPressed: _apagar,
                style: FilledButton.styleFrom(backgroundColor: t.negative, foregroundColor: t.fgInverse),
                child: const Text('Apagar')),
        ]),
      ]),
    );
  }

  Widget _detalhePorta(TradeTokens t, Equipamento eq, PortaVista p) {
    final up = p.estado == 'up';
    final u = eq.uplinks[p.nome] as Map?;
    final rel = relativo(p.desde);
    final ligado = u == null ? null : (u['filho'] != null ? 'switch ${u['filho']}' : '${u['vigiados'] ?? 0} aparelhos vigiados');
    Widget linha(String k, String v) => Padding(
          padding: EdgeInsets.symmetric(vertical: t.space1),
          child: Row(children: [
            SizedBox(width: 120, child: Text(k, style: TradeType.label.copyWith(color: t.fgSecondary))),
            Expanded(child: Text(v, style: TradeType.bodyMd.copyWith(color: t.fgPrimary))),
          ]),
        );
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Porta ${p.nome}', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        linha('Estado', switch (p.estado) { 'up' => 'Com link', 'caiu' => 'Caiu', _ => 'Sem link' }),
        if (up && p.velocidade != null) linha('Velocidade', velocidadeTxt(p.velocidade!)),
        if (rel.isNotEmpty) linha(up ? 'Com link' : 'Sem link', 'há $rel'),
        if (ligado != null) linha('Ligado a', ligado),
      ]),
    );
  }

  Widget _historico(TradeTokens t) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Histórico', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space3),
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Eventos do syslog', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space3),
          if (_eventos.isEmpty) Text('Sem eventos.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          for (final e in _eventos.map((j) => Evento.fromJson(j as Map<String, dynamic>)))
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Text('${formatEventoHora(e.recebidoEm)} · ${e.mensagem}', style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
            ),
        ]),
      );
}

import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/heartbeat.dart';

class MkDetailScreen extends StatefulWidget {
  const MkDetailScreen({super.key, required this.api, required this.id, this.chooseInterfaces = false});
  final ApiClient api;
  final String id;

  /// Logo depois de criar a MK: abre a escolha de interfaces.
  final bool chooseInterfaces;

  @override
  State<MkDetailScreen> createState() => _MkDetailScreenState();
}

class _MkDetailScreenState extends State<MkDetailScreen> {
  MkDetail? _mk;
  List<HistEvent> _hist = const [];
  List<String> _alertas = const []; // mesmas regras do painel: vêm de /status
  String? _error;

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      if (mounted && widget.chooseInterfaces && _mk != null) _pickInterfaces();
    });
  }

  Future<void> _load() async {
    try {
      final mk = await widget.api.mk(widget.id);
      final hist = await widget.api.history(widget.id);
      var alertas = const <String>[];
      try {
        alertas = (await widget.api.status()).mks.where((m) => m.id == widget.id).firstOrNull?.alertas ?? alertas;
      } catch (e) {
        if (e is ApiError && e.status == 401) rethrow; // outras falhas: detalhe sem alertas
      }
      if (mounted) {
        setState(() {
          _mk = mk;
          _hist = hist;
          _alertas = alertas;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && !sessionExpired(context, e)) setState(() => _error = errorText(e));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  Future<bool> _confirm(String title, String body, String ok) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
          ],
        ),
      ) ??
      false;

  Future<void> _pickInterfaces() async {
    List<IfaceInfo> all;
    try {
      all = await widget.api.interfaces(widget.id);
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
      return;
    }
    if (!mounted) return;
    final chosen = {...?_mk?.interfacesVigiadas};
    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: const Text('Escolher interfaces'),
          content: SizedBox(
            width: 360,
            child: all.isEmpty
                ? const Text('Nenhuma interface encontrada.')
                : ListView(shrinkWrap: true, children: [
                    for (final i in all)
                      CheckboxListTile(
                        value: chosen.contains(i.nome),
                        title: Text(i.nome),
                        subtitle: Text(i.running ? 'ativa' : 'inativa'),
                        onChanged: (v) => setS(() => v! ? chosen.add(i.nome) : chosen.remove(i.nome)),
                      ),
                  ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Salvar')),
          ],
        ),
      ),
    );
    if (saved == true) await _run(() => widget.api.setWatched(widget.id, chosen.toList()));
  }

  Future<void> _acceptCert() async {
    if (await _confirm('Aceitar novo certificado',
        'Confirme só se a troca do aparelho ou do certificado foi esperada. O monitor passará a confiar no certificado atual.', 'Aceitar')) {
      await _run(() => widget.api.acceptCert(widget.id));
    }
  }

  Future<void> _delete() async {
    if (!await _confirm('Remover MK', 'Remover "${_mk!.nome}" do monitoramento?', 'Remover')) return;
    try {
      await widget.api.deleteMk(widget.id);
      if (mounted) Navigator.of(context).pushNamedAndRemoveUntil('/painel', (_) => false);
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final mk = _mk;
    return Scaffold(
      appBar: AppBar(
        leading: backFallback(context),
        backgroundColor: t.bgPage,
        title: Text(mk?.nome ?? 'MK', style: TradeType.heading3.copyWith(color: t.fgPrimary)),
        actions: [const ThemeToggle(), SizedBox(width: t.space2)],
      ),
      body: mk == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!, style: TradeType.bodyMd.copyWith(color: t.negative)))
          : ListView(padding: EdgeInsets.all(t.space6), children: [
              _header(context, t, mk),
              SizedBox(height: t.space4),
              _interfaces(context, t, mk),
              SizedBox(height: t.space4),
              _history(t),
            ]),
    );
  }

  Widget _header(BuildContext context, TradeTokens t, MkDetail mk) {
    final e = mk.estado;
    final status = e?.status ?? 'aguardando';
    final alert = _alertas.isNotEmpty;
    final nums = dataStyle(context, TradeType.dataSm);
    Widget metric(String label, String value) => Padding(
          padding: EdgeInsets.only(right: t.space8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TradeType.label.copyWith(color: t.fgSecondary)),
            Text(value.trim().isEmpty ? '—' : value, style: nums),
          ]),
        );
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: t.space4, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusPill(status: status, alert: alert, desde: e?.desde),
          if (e?.detalhe != null) Text(e!.detalhe!, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        ]),
        SizedBox(height: t.space4),
        if (alert)
          Padding(
            padding: EdgeInsets.only(top: t.space3),
            child: Text(_alertas.join(' · '), style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
          ),
        SizedBox(height: t.space4),
        HeartbeatLine(status: status, alert: alert, width: 240, height: 56),
        SizedBox(height: t.space4),
        Wrap(runSpacing: t.space3, children: [
          metric('CPU', e?.cpu == null ? '—' : '${e!.cpu!.round()}%'),
          metric('Memória', e?.mem == null ? '—' : '${e!.mem!.round()}%'),
          metric('Uptime', e?.uptime ?? '—'),
          metric('Versão', e?.versao ?? '—'),
          metric('IP no túnel', mk.ipTunel),
          metric('IP público', mk.ipPublico),
          metric('Usuário', mk.usuario),
        ]),
        SizedBox(height: t.space6),
        Wrap(spacing: t.space2, runSpacing: t.space2, children: [
          FilledButton(
              onPressed: () => Navigator.of(context).pushNamed('/mk/${mk.id}/editar').then((_) => _load()),
              child: const Text('Editar')),
          OutlinedButton(onPressed: _pickInterfaces, child: const Text('Escolher interfaces')),
          OutlinedButton(onPressed: _acceptCert, child: const Text('Aceitar novo certificado')),
          FilledButton(
              onPressed: _delete,
              style: FilledButton.styleFrom(backgroundColor: t.negative, foregroundColor: t.fgInverse),
              child: const Text('Remover')),
        ]),
      ]),
    );
  }

  Widget _interfaces(BuildContext context, TradeTokens t, MkDetail mk) {
    final ifaces = mk.estado?.ifaces ?? const <String, bool>{};
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Interfaces vigiadas', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        if (mk.interfacesVigiadas.isEmpty)
          Text('Nenhuma interface escolhida.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        for (final n in mk.interfacesVigiadas)
          Padding(
            padding: EdgeInsets.symmetric(vertical: t.space1),
            child: Row(children: [
              Expanded(child: Text(n, style: dataStyle(context, TradeType.dataSm))),
              Text(
                ifaces[n] == null ? 'sem leitura' : (ifaces[n]! ? 'de pé' : 'caída'),
                style: TradeType.label.copyWith(color: ifaces[n] == null ? t.fgSecondary : (ifaces[n]! ? t.positive : t.negative)),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _history(TradeTokens t) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Histórico', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space3),
          if (_hist.isEmpty) Text('Sem eventos.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          for (final h in _hist)
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Text(
                [
                  _tipos[h.tipo] ?? statusLabel(h.tipo, false),
                  _eventos[h.evento] ?? h.evento,
                  if (h.detalhe != null) h.detalhe!,
                  formatDateTime(h.fim ?? h.inicio), // retorno/encerrado: quando acabou
                  if (h.duracaoS != null) formatDuration(h.duracaoS!),
                ].where((x) => x.isNotEmpty).join(' · '),
                style: TradeType.bodyMd.copyWith(color: t.fgPrimary),
              ),
            ),
        ]),
      );
}

const _eventos = {'queda': 'Queda', 'retorno': 'Retorno', 'encerrado': 'Encerrado'};

// Tipos que não são status de MK; os demais vêm de statusLabel.
const _tipos = {
  'cpu_alta': 'CPU alta',
  'memoria_alta': 'Memória alta',
  'interface_caida': 'Interface caída',
  'falha_sede': 'Falha da sede',
};

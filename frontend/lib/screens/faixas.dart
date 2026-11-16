import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/inventario.dart';

class FaixasScreen extends StatefulWidget {
  const FaixasScreen({
    super.key,
    required this.api,
    this.pollEvery = const Duration(seconds: 5),
    this.pollMax = const Duration(minutes: 2),
  });
  final ApiClient api;

  /// Depois de "Atualizar": recarrega a cada [pollEvery] até algum `lido_em` mudar ou passar [pollMax].
  final Duration pollEvery, pollMax;

  @override
  State<FaixasScreen> createState() => _FaixasScreenState();
}

class _FaixasScreenState extends State<FaixasScreen> {
  FaixasData? _data;
  String? _error;
  Timer? _poll;
  bool _atualizando = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<FaixasData?> _load() async {
    try {
      final d = await widget.api.faixas();
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
      return d;
    } catch (e) {
      if (mounted && !sessionExpired(context, e)) setState(() => _error = errorText(e));
      return null;
    }
  }

  Map<String, String?> _lidos(FaixasData? d) => {for (final m in d?.mks ?? const <FaixaMk>[]) m.id: m.lidoEm};

  Future<void> _atualizar() async {
    final antes = _lidos(_data);
    try {
      await widget.api.pedirAtualizarFaixas();
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
      return;
    }
    setState(() => _atualizando = true);
    final fim = DateTime.now().add(widget.pollMax);
    _poll?.cancel();
    _poll = Timer.periodic(widget.pollEvery, (timer) async {
      final d = await _load();
      final mudou = d != null && _lidos(d).entries.any((e) => antes[e.key] != e.value);
      if (mudou || DateTime.now().isAfter(fim)) {
        timer.cancel();
        if (mounted) setState(() => _atualizando = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final d = _data;
    return Scaffold(
      appBar: AppBar(
        leading: backFallback(context),
        backgroundColor: t.bgPage,
        title: Text('Faixas de IP', style: TradeType.heading3.copyWith(color: t.fgPrimary)),
        actions: [const ThemeToggle(), SizedBox(width: t.space2)],
      ),
      body: d == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!, style: TradeType.bodyMd.copyWith(color: t.negative)))
          : ListView(padding: EdgeInsets.all(t.space6), children: [
              if (d.sobreposicoes.isNotEmpty) ...[_sobreposicoes(t, d), SizedBox(height: t.space4)],
              TradeCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Conferir faixa', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
                  SizedBox(height: t.space3),
                  ConferirCampo(label: 'Faixa (ex.: 10.30.0.0/24)', conferir: widget.api.conferirFaixa),
                ]),
              ),
              SizedBox(height: t.space4),
              Row(children: [
                Expanded(child: Text('Condomínios', style: TradeType.heading4.copyWith(color: t.fgPrimary))),
                if (_atualizando)
                  Padding(
                    padding: EdgeInsets.only(right: t.space3),
                    child: Text('Atualizando…', style: TradeType.label.copyWith(color: t.fgSecondary)),
                  ),
                OutlinedButton(onPressed: _atualizando ? null : _atualizar, child: const Text('Atualizar')),
              ]),
              SizedBox(height: t.space3),
              for (final m in d.mks) ...[_mk(context, t, m), SizedBox(height: t.space4)],
              TradeCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Sede', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
                  SizedBox(height: t.space3),
                  if (d.sede.isEmpty) Text('Sem redes lidas.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
                  for (final r in d.sede)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: t.space1),
                      child: Text(r, style: dataStyle(context, TradeType.dataSm)),
                    ),
                ]),
              ),
            ]),
    );
  }

  Widget _sobreposicoes(TradeTokens t, FaixasData d) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Faixas sobrepostas', style: TradeType.heading4.copyWith(color: t.warning)),
          SizedBox(height: t.space3),
          for (final s in d.sobreposicoes)
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space1),
              child: Text('${s.a} (${s.redeA}) sobrepõe ${s.b} (${s.redeB})',
                  style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
            ),
        ]),
      );

  Widget _mk(BuildContext context, TradeTokens t, FaixaMk m) {
    final hora = formatHora(m.lidoEm);
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(m.nome, style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          if (hora.isNotEmpty) Text('lido $hora', style: TradeType.label.copyWith(color: t.fgSecondary)),
          if (m.desatualizado) Text('dados desatualizados', style: TradeType.label.copyWith(color: t.warning)),
          if (m.erro != null) Text(m.erro!, style: TradeType.label.copyWith(color: t.warning)),
        ]),
        SizedBox(height: t.space3),
        if (m.redes.isEmpty) Text('Sem redes lidas.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        for (final r in m.redes)
          Padding(
            padding: EdgeInsets.symmetric(vertical: t.space1),
            child: Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 168, child: Text(r.rede, style: dataStyle(context, TradeType.dataSm))),
              if (r.interface != null) Text(r.interface!, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
              if (r.tunel) Selo('túnel', t.info),
            ]),
          ),
      ]),
    );
  }
}

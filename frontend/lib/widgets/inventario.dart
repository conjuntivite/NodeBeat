import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'common.dart';

const _textoAberto = 'aberto para qualquer IP (sem restrição na regra)';

/// "HH:mm" no horário local; vazio se inválido.
String formatHora(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  return d == null ? '' : '${two(d.hour)}:${two(d.minute)}';
}

/// "DD/MM" no horário local; vazio se inválido.
String formatDia(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  return d == null ? '' : '${two(d.day)}/${two(d.month)}';
}

/// Selo em pílula (borda e texto na mesma cor semântica).
class Selo extends StatelessWidget {
  const Selo(this.texto, this.cor, {super.key});
  final String texto;
  final Color cor;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: t.space3, vertical: t.space1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.radiusPill),
        border: Border.all(color: cor),
      ),
      child: Text(texto, style: TradeType.label.copyWith(color: cor)),
    );
  }
}

/// Resultado de uma conferência: veredito colorido, detalhes e avisos.
class ResultadoConferencia extends StatelessWidget {
  const ResultadoConferencia(this.c, {super.key});
  final Conferencia c;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final (texto, cor) = switch (c.resultado) {
      'em_uso' => ('Em uso', t.negative),
      'livre' => ('Livre', t.positive),
      'sem_dados' => ('Sem dados', t.warning),
      _ => ('Fora da faixa', t.warning),
    };
    final mono = dataStyle(context, TradeType.dataSm);
    final v = c.visto;
    final detalhes = [
      ...c.colisoes,
      ...c.usos,
      if (v != null) [v.ip, if (v.hostName != null) v.hostName!, if (v.mac != null) v.mac!].join(' · '),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(texto, style: TradeType.heading4.copyWith(color: cor)),
      for (final d in detalhes) Text(d, style: mono),
      if (c.faltam.isNotEmpty)
        Text('Faltam dados de: ${c.faltam.join(', ')}', style: TradeType.bodyMd.copyWith(color: t.warning)),
      if (c.desatualizado) Text('Dados desatualizados', style: TradeType.bodyMd.copyWith(color: t.warning)),
      for (final a in c.avisos) Text(a, style: TradeType.bodyMd.copyWith(color: t.warning)),
    ]);
  }
}

/// Campo + botão "Conferir" + resultado. [trailing] fica entre o campo e o botão.
class ConferirCampo extends StatefulWidget {
  const ConferirCampo({super.key, required this.label, required this.conferir, this.trailing, this.numerico = false});
  final String label;
  final Future<Conferencia> Function(String valor) conferir;
  final Widget? trailing;
  final bool numerico;

  @override
  State<ConferirCampo> createState() => _ConferirCampoState();
}

class _ConferirCampoState extends State<ConferirCampo> {
  final _ctl = TextEditingController();
  Conferencia? _res;
  String? _erro;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final v = _ctl.text.trim();
    if (v.isEmpty) return;
    try {
      final r = await widget.conferir(v);
      if (mounted) {
        setState(() {
          _res = r;
          _erro = null;
        });
      }
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      setState(() {
        _res = null;
        _erro = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: t.space2, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 240,
          child: TextField(
            controller: _ctl,
            keyboardType: widget.numerico ? TextInputType.number : TextInputType.text,
            style: dataStyle(context, TradeType.dataSm),
            decoration: InputDecoration(labelText: widget.label),
            onSubmitted: (_) => _go(),
          ),
        ),
        ?widget.trailing,
        OutlinedButton(onPressed: _go, child: const Text('Conferir')),
      ]),
      if (_erro != null)
        Padding(
          padding: EdgeInsets.only(top: t.space2),
          child: Text(_erro!, style: TradeType.bodyMd.copyWith(color: t.negative)),
        ),
      if (_res != null) Padding(padding: EdgeInsets.only(top: t.space3), child: ResultadoConferencia(_res!)),
    ]);
  }
}

/// Carrega um recurso do inventário; erros (exceto 401) viram texto no cartão.
mixin _Carrega<W extends StatefulWidget, T> on State<W> {
  T? dados;
  String? erro;
  Future<T> buscar();

  Future<void> carregar() async {
    try {
      final d = await buscar();
      if (mounted) {
        setState(() {
          dados = d;
          erro = null;
        });
      }
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      setState(() => erro = errorText(e));
    }
  }

  @override
  void initState() {
    super.initState();
    carregar();
  }
}

Widget _vazio(TradeTokens t, String? erro, String texto) =>
    Text(erro ?? texto, style: TradeType.bodyMd.copyWith(color: erro != null ? t.negative : t.fgSecondary));

Widget _linha(TradeTokens t, List<Widget> filhos) => Padding(
      padding: EdgeInsets.symmetric(vertical: t.space1),
      child: Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: filhos),
    );

/// Estado da leitura no topo do cartão: "lido HH:mm", desatualizado e erro; "Sem leitura ainda" se nunca lida.
Widget _leitura(TradeTokens t, InventarioMk? inv) {
  if (inv == null) return const SizedBox.shrink();
  final aviso = TradeType.label.copyWith(color: t.warning);
  final hora = formatHora(inv.lidoEm);
  return Padding(
    padding: EdgeInsets.only(bottom: t.space3),
    child: Wrap(spacing: t.space3, runSpacing: t.space1, children: [
      if (inv.lidoEm == null) Text('Sem leitura ainda', style: aviso),
      if (hora.isNotEmpty) Text('lido $hora', style: TradeType.label.copyWith(color: t.fgSecondary)),
      if (inv.desatualizado && inv.lidoEm != null) Text('dados desatualizados', style: aviso),
      if (inv.erro != null) Text(inv.erro!, style: aviso),
    ]),
  );
}

class PortasCard extends StatefulWidget {
  const PortasCard({super.key, required this.api, required this.id});
  final ApiClient api;
  final String id;

  @override
  State<PortasCard> createState() => _PortasCardState();
}

class _PortasCardState extends State<PortasCard> with _Carrega<PortasCard, InventarioMk> {
  String _proto = 'tcp';

  @override
  Future<InventarioMk> buscar() => widget.api.inventario(widget.id);

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final mono = dataStyle(context, TradeType.dataSm);
    final inv = dados;
    final servicos = [...?inv?.servicos.where((s) => s.ativo)];
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Portas', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        _leitura(t, inv),
        if ((inv == null || inv.nat.isEmpty) && (erro != null || inv?.lidoEm != null))
          _vazio(t, erro, 'Nenhum redirecionamento de porta.'),
        for (final n in inv?.nat ?? const <NatRegra>[])
          _linha(t, [
            Text('${n.dstPort ?? '—'} → ${n.toAddresses ?? '—'}:${n.toPorts ?? n.dstPort ?? '—'}', style: mono),
            Text((n.protocolo ?? '').toUpperCase(), style: TradeType.label.copyWith(color: t.fgSecondary)),
            if (n.comentario != null && n.comentario!.isNotEmpty)
              Text(n.comentario!, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
            if (!n.ativo) Selo('desativada', t.fgSecondary),
            if (n.ativo && n.aberto) Selo(_textoAberto, t.warning),
          ]),
        if (servicos.isNotEmpty) ...[
          SizedBox(height: t.space4),
          Text('Serviços ativos', style: TradeType.label.copyWith(color: t.fgSecondary)),
          for (final s in servicos)
            _linha(t, [
              Text('${s.nome} ${s.porta ?? ''}'.trim(), style: mono),
              if (s.aberto) Selo(_textoAberto, t.warning),
            ]),
        ],
        SizedBox(height: t.space6),
        ConferirCampo(
          label: 'Conferir porta',
          numerico: true,
          conferir: (v) => widget.api.conferirPorta(widget.id, int.tryParse(v) ?? -1, _proto),
          trailing: StatefulBuilder(
            builder: (c, setS) => SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'tcp', label: Text('TCP')),
                ButtonSegment(value: 'udp', label: Text('UDP')),
              ],
              selected: {_proto},
              onSelectionChanged: (s) => setS(() => _proto = s.first),
            ),
          ),
        ),
      ]),
    );
  }
}

class IpsCard extends StatefulWidget {
  const IpsCard({super.key, required this.api, required this.id});
  final ApiClient api;
  final String id;

  @override
  State<IpsCard> createState() => _IpsCardState();
}

class _IpsCardState extends State<IpsCard> with _Carrega<IpsCard, List<IpVisto>> {
  InventarioMk? _inv;

  @override
  Future<List<IpVisto>> buscar() async {
    final ips = await widget.api.ips(widget.id);
    try {
      _inv = await widget.api.inventario(widget.id);
    } catch (_) {
      _inv = null; // o estado da leitura é secundário; a lista de IPs já carregou
    }
    return ips;
  }

  Future<void> _esquecer(IpVisto v) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Esquecer IP'),
            content: Text('Esquecer ${v.ip} do histórico desta MK?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Esquecer')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await widget.api.esquecerIp(widget.id, v.ip);
      await carregar();
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final mono = dataStyle(context, TradeType.dataSm);
    final lista = dados;
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('IPs', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        _leitura(t, _inv),
        if ((lista == null || lista.isEmpty) && (erro != null || _inv?.lidoEm != null))
          _vazio(t, erro, 'Nenhum IP visto.'),
        for (final v in lista ?? const <IpVisto>[])
          _linha(t, [
            SizedBox(width: 128, child: Text(v.ip, style: mono)),
            Text(v.mac ?? '—', style: mono),
            if (v.hostName != null) Text(v.hostName!, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
            if (formatDia(v.ultimoVisto).isNotEmpty)
              Text('visto ${formatDia(v.ultimoVisto)}', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
            if (v.emUso) Selo('em uso', t.negative),
            if (v.fixo) Selo('fixo', t.info),
            TextButton(onPressed: () => _esquecer(v), child: Text('esquecer', semanticsLabel: 'Esquecer ${v.ip}')),
          ]),
        SizedBox(height: t.space6),
        ConferirCampo(label: 'Conferir IP', conferir: (v) => widget.api.conferirIp(widget.id, v)),
      ]),
    );
  }
}

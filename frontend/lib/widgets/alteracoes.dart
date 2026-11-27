import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'common.dart';

const _semRw = "Para alterar esta MK pelo NodeBeat, aplique o script 'permitir alterações' da página Preparar MK e preencha a senha no cadastro.";

String _via(String? v) => v == 'tunel' ? 'pelo túnel' : 'pelo IP público';

bool _ipValido(String s) {
  final p = s.split('.');
  return p.length == 4 && p.every((x) => RegExp(r'^\d{1,3}$').hasMatch(x) && int.parse(x) <= 255);
}

/// Base dos dois cartões: lê a MK só quando o usuário pede e guarda o resultado da última ação.
abstract class _EstadoAlteracao<W extends StatefulWidget, T> extends State<W> {
  T? dados;
  String? erro, msg;
  bool carregando = false;

  Future<T> buscar();

  Future<void> carregar() => executar(() async => dados = await buscar());

  /// Roda [acao] e mostra o erro (exceto 401) no cartão; [sucesso] vira a mensagem se a ação não definir outra.
  Future<void> executar(Future<void> Function() acao, {String? sucesso}) async {
    setState(() {
      carregando = true;
      erro = null;
      msg = null;
    });
    try {
      await acao();
      if (mounted) setState(() => msg ??= sucesso);
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      setState(() => erro = errorText(e));
    } finally {
      if (mounted) setState(() => carregando = false);
    }
  }

  Widget aviso(TradeTokens t, bool temRw) => temRw
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.only(bottom: t.space3),
          child: Text(_semRw, style: TradeType.bodyMd.copyWith(color: t.warning)),
        );

  Widget retorno(TradeTokens t) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (erro != null) Text(erro!, style: TradeType.bodyMd.copyWith(color: t.negative)),
        if (msg != null) Text(msg!, style: TradeType.bodyMd.copyWith(color: t.positive)),
      ]);
}

class IpsecCard extends StatefulWidget {
  const IpsecCard({super.key, required this.api, required this.id, required this.temRw, required this.ipsSede});
  final ApiClient api;
  final String id;
  final bool temRw;
  final List<String> ipsSede;

  @override
  State<IpsecCard> createState() => _IpsecCardState();
}

class _IpsecCardState extends _EstadoAlteracao<IpsecCard, List<PeerIpsec>> {
  @override
  Future<List<PeerIpsec>> buscar() async => (await widget.api.peers(widget.id)).peers;

  Future<void> _trocar(PeerIpsec p) async {
    final novo = await showDialog<String>(
      context: context,
      builder: (c) => _TrocarPeerDialog(atual: p.endereco, ipsSede: widget.ipsSede, porDominio: p.porDominio),
    );
    if (novo == null) return;
    await executar(() async {
      final r = await widget.api.trocarPeer(widget.id, p.id, novo);
      msg = r.confirmado ? 'Peer trocado ${_via(r.via)}' : 'Enviado; não deu para confirmar';
      if (r.policiesErro.isNotEmpty) msg = '$msg; policy ${r.policiesErro.join(', ')} não foi atualizada';
      dados = await buscar();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final mono = dataStyle(context, TradeType.dataSm);
    final pode = widget.temRw && !carregando;
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('IPsec', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        aviso(t, widget.temRw),
        OutlinedButton(onPressed: pode ? carregar : null, child: Text(dados == null ? 'Carregar peers' : 'Recarregar peers')),
        SizedBox(height: t.space3),
        if (dados != null && dados!.isEmpty) Text('Nenhum peer.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        for (final p in dados ?? const <PeerIpsec>[])
          Padding(
            padding: EdgeInsets.symmetric(vertical: t.space1),
            child: Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(p.nome ?? p.id, style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
              Text(p.endereco, style: mono),
              if (p.desativado) Selo('desativado', t.fgSecondary),
              if (p.porDominio)
                Text('pelo domínio: sobe sozinho pelo load balance', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
              OutlinedButton(onPressed: pode ? () => _trocar(p) : null, child: const Text('Trocar peer')),
            ]),
          ),
        retorno(t),
      ]),
    );
  }
}

class _TrocarPeerDialog extends StatefulWidget {
  const _TrocarPeerDialog({required this.atual, required this.ipsSede, required this.porDominio});
  final String atual;
  final bool porDominio;
  final List<String> ipsSede;

  @override
  State<_TrocarPeerDialog> createState() => _TrocarPeerDialogState();
}

class _TrocarPeerDialogState extends State<_TrocarPeerDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final novo = _ctl.text.trim();
    return AlertDialog(
      title: const Text('Trocar peer'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.porDominio)
            Padding(
              padding: EdgeInsets.only(bottom: t.space3),
              child: Text('Este peer usa domínio e sobe sozinho pelo load balance; trocar para IP fixo tira isso.',
                  style: TradeType.bodyMd.copyWith(color: t.warning)),
            ),
          Wrap(spacing: t.space2, children: [
            for (final ip in widget.ipsSede) ActionChip(label: Text(ip), onPressed: () => setState(() => _ctl.text = ip)),
          ]),
          TextField(
            controller: _ctl,
            style: dataStyle(context, TradeType.dataSm),
            decoration: const InputDecoration(labelText: 'Novo endereço (IPv4)'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: t.space3),
          Text('Atual: ${widget.atual} → Novo: ${novo.isEmpty ? '—' : novo}', style: dataStyle(context, TradeType.dataSm)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _ipValido(novo) ? () => Navigator.pop(context, novo) : null, child: const Text('Trocar')),
      ],
    );
  }
}

class PortasLiberadasCard extends StatefulWidget {
  const PortasLiberadasCard({super.key, required this.api, required this.id, required this.temRw});
  final ApiClient api;
  final String id;
  final bool temRw;

  @override
  State<PortasLiberadasCard> createState() => _PortasLiberadasCardState();
}

class _PortasLiberadasCardState extends _EstadoAlteracao<PortasLiberadasCard, List<Liberacao>> {
  @override
  Future<List<Liberacao>> buscar() => widget.api.liberacoes(widget.id);

  Future<void> _liberar() async {
    var ips = const <IpVisto>[];
    try {
      ips = await widget.api.ips(widget.id);
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return; // sem sugestões, o campo continua livre
    }
    if (!mounted) return;
    final f = await showDialog<_Form>(context: context, builder: (c) => _LiberarDialog(ips: [for (final i in ips) i.ip]));
    if (f == null) return;
    await executar(() async {
      final r = await widget.api.liberarPorta(widget.id,
          protocolo: f.protocolo, portaExterna: f.externa, ipInterno: f.ip, portaInterna: f.interna, descricao: f.descricao);
      msg = 'Porta liberada ${_via(r.via)}${r.wan != null ? ' · WAN ${r.wan}' : ''}'
          '${r.avisos.isEmpty ? '' : ' · ${r.avisos.join(' · ')}'}';
      dados = await buscar();
    });
  }

  Future<void> _remover(Liberacao l) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Remover liberação'),
            content: Text("Remover a liberação '${l.descricao}' da MK?"),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remover')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await executar(() async {
      await widget.api.removerLiberacao(widget.id, l.descricao);
      dados = await buscar();
    }, sucesso: 'Liberação removida');
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final mono = dataStyle(context, TradeType.dataSm);
    final pode = widget.temRw && !carregando;
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Portas liberadas', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        aviso(t, widget.temRw),
        Wrap(spacing: t.space2, runSpacing: t.space2, children: [
          OutlinedButton(onPressed: pode ? carregar : null, child: Text(dados == null ? 'Carregar portas' : 'Recarregar portas')),
          OutlinedButton(onPressed: pode ? _liberar : null, child: const Text('Liberar porta')),
        ]),
        SizedBox(height: t.space3),
        if (dados != null && dados!.isEmpty)
          Text('Nenhuma porta liberada pelo NodeBeat.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        for (final l in dados ?? const <Liberacao>[])
          Padding(
            padding: EdgeInsets.symmetric(vertical: t.space1),
            child: Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(l.descricao, style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
              Text('${l.portaExterna ?? '—'} → ${l.ipInterno ?? '—'}:${l.portaInterna ?? '—'}', style: mono),
              Text(l.protocolos.join('/').toUpperCase(), style: TradeType.label.copyWith(color: t.fgSecondary)),
              if (l.wan != null) Text(l.wan!, style: mono),
              if (l.desativada) Selo('desativada', t.fgSecondary),
              TextButton(onPressed: pode ? () => _remover(l) : null, child: Text('Remover', semanticsLabel: 'Remover ${l.descricao}')),
            ]),
          ),
        retorno(t),
      ]),
    );
  }
}

class _Form {
  _Form(this.protocolo, this.externa, this.ip, this.interna, this.descricao);
  final String protocolo, ip, descricao;
  final int externa, interna;
}

class _LiberarDialog extends StatefulWidget {
  const _LiberarDialog({required this.ips});
  final List<String> ips;

  @override
  State<_LiberarDialog> createState() => _LiberarDialogState();
}

class _LiberarDialogState extends State<_LiberarDialog> {
  final _ext = TextEditingController(), _ip = TextEditingController(), _int = TextEditingController(), _desc = TextEditingController();
  String _proto = 'tcp';

  @override
  void dispose() {
    for (final c in [_ext, _ip, _int, _desc]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _porta(String s) {
    final n = int.tryParse(s.trim());
    return n != null && n >= 1 && n <= 65535 ? n : null;
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final externa = _porta(_ext.text);
    final interna = _int.text.trim().isEmpty ? externa : _porta(_int.text);
    final ip = _ip.text.trim(), desc = _desc.text.trim();
    final valido = externa != null && interna != null && _ipValido(ip) && desc.isNotEmpty;
    Widget campo(TextEditingController c, String label, {bool num = false}) => TextField(
          controller: c,
          keyboardType: num ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => setState(() {}),
        );
    return AlertDialog(
      title: const Text('Liberar porta'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: t.space2, children: [
              for (final p in const ['tcp', 'udp', 'ambos'])
                ChoiceChip(label: Text(p), selected: _proto == p, onSelected: (_) => setState(() => _proto = p)),
            ]),
            campo(_ext, 'Porta externa', num: true),
            campo(_ip, 'IP interno'),
            Wrap(spacing: t.space2, children: [
              for (final s in widget.ips.take(8)) ActionChip(label: Text(s), onPressed: () => setState(() => _ip.text = s)),
            ]),
            campo(_int, 'Porta interna (padrão: a externa)', num: true),
            campo(_desc, 'Descrição'),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: valido ? () => Navigator.pop(context, _Form(_proto, externa, ip, interna, desc)) : null,
          child: const Text('Liberar'),
        ),
      ],
    );
  }
}

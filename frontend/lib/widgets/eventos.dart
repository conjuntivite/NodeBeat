import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../mk_script.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'common.dart';
import 'inventario.dart';

const _filtros = [
  ('Todos', null),
  ('Logins', 'login'),
  ('Falhas de login', 'login_falha'),
  ('Configuração', 'config'),
  ('Interfaces', 'interface'),
  ('IPsec', 'ipsec'),
  ('DHCP', 'dhcp'),
  ('PPPoE', 'pppoe'),
  ('Reboot', 'reboot'),
  ('Erros', 'erro'),
];

const _periodos = [('24 h', Duration(hours: 24)), ('7 dias', Duration(days: 7)), ('30 dias', Duration(days: 30))];

const _limite = 200;

/// "dd/MM HH:mm:ss" no horário local.
String formatEventoHora(DateTime utc) {
  final d = utc.toLocal();
  return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

Color _corSelo(TradeTokens t, String tipo) => switch (tipo) {
      'login_falha' || 'erro' => t.negative,
      'login' || 'config' => t.info,
      _ => t.fgSecondary,
    };

class EventosCard extends StatefulWidget {
  const EventosCard({super.key, required this.api, required this.id, required this.ipTunel});
  final ApiClient api;
  final String id;
  final String ipTunel;

  @override
  State<EventosCard> createState() => _EventosCardState();
}

class _EventosCardState extends State<EventosCard> with Carrega<EventosCard, EventosPagina> {
  String? _tipo;
  int _periodo = 0;
  final _busca = TextEditingController();
  final _extra = <Evento>[]; // páginas seguintes ("Mostrar mais")
  bool _temMais = false;

  @override
  void dispose() {
    _busca.dispose();
    super.dispose();
  }

  Future<EventosPagina> _pedir({DateTime? ate}) => widget.api.eventos(
        widget.id,
        tipos: [?_tipo],
        desde: DateTime.now().subtract(_periodos[_periodo].$2),
        ate: ate,
        q: _busca.text.trim(),
        limite: _limite,
      );

  int _seq = 0; // respostas de uma geração anterior são descartadas
  bool _buscandoMais = false;

  @override
  Future<EventosPagina> buscar() => _pedir();

  /// Recarrega a primeira página; só a última chamada vale.
  @override
  Future<void> carregar() async {
    final s = ++_seq;
    _buscandoMais = false;
    try {
      final p = await buscar();
      if (!mounted || s != _seq) return;
      setState(() {
        dados = p;
        erro = null;
        _extra.clear();
        _temMais = p.eventos.length >= _limite;
      });
    } catch (e) {
      if (!mounted || s != _seq || sessionExpired(context, e)) return;
      setState(() => erro = errorText(e));
    }
  }

  Future<void> _maisAntigos() async {
    if (_buscandoMais) return;
    final s = _seq;
    final todos = [...?dados?.eventos, ..._extra];
    setState(() => _buscandoMais = true);
    try {
      final p = await _pedir(ate: todos.last.recebidoEm);
      if (!mounted || s != _seq) return;
      setState(() {
        _extra.addAll(p.eventos);
        _temMais = p.eventos.length >= _limite;
        _buscandoMais = false;
      });
    } catch (e) {
      if (!mounted || s != _seq || sessionExpired(context, e)) return;
      setState(() {
        erro = errorText(e);
        _buscandoMais = false;
      });
    }
  }

  void _filtrar(VoidCallback mudar) {
    setState(mudar);
    carregar();
  }

  Future<void> _ligar() async {
    String? ipOrigem;
    String? falha;
    try {
      ipOrigem = (await widget.api.prepararMk()).ipOrigem;
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      falha = errorText(e);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => _LigarDialogo(
        script: ipOrigem == null ? null : scriptLigarEventos(ipOrigem: ipOrigem, ipTunel: widget.ipTunel),
        falha: falha,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final p = dados;
    final eventos = [...?p?.eventos, ..._extra];
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Eventos', style: TradeType.heading4.copyWith(color: t.fgPrimary))),
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Atualizar', onPressed: carregar),
        ]),
        SizedBox(height: t.space3),
        Wrap(spacing: t.space2, runSpacing: t.space2, children: [
          for (final (nome, tipo) in _filtros)
            ChoiceChip(label: Text(nome), selected: _tipo == tipo, onSelected: (_) => _filtrar(() => _tipo = tipo)),
        ]),
        SizedBox(height: t.space3),
        Wrap(spacing: t.space2, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (var i = 0; i < _periodos.length; i++)
            ChoiceChip(label: Text(_periodos[i].$1), selected: _periodo == i, onSelected: (_) => _filtrar(() => _periodo = i)),
          SizedBox(
            width: 240,
            child: TextField(
              controller: _busca,
              decoration: const InputDecoration(labelText: 'Buscar'),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => carregar(),
            ),
          ),
        ]),
        SizedBox(height: t.space4),
        if (erro != null) Text(erro!, style: TradeType.bodyMd.copyWith(color: t.negative)),
        if (p != null && !p.syslogAtivo && eventos.isEmpty)
          Wrap(spacing: t.space3, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('Esta MK não está mandando eventos', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
            OutlinedButton(onPressed: _ligar, child: const Text('Ligar eventos')),
          ])
        else if (p != null && eventos.isEmpty)
          Text('Nenhum evento no período.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        for (final e in eventos)
          Padding(
            padding: EdgeInsets.symmetric(vertical: t.space1),
            child: Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(formatEventoHora(e.recebidoEm), style: dataStyle(context, TradeType.dataSm)),
              Selo(e.tipo, _corSelo(t, e.tipo)),
              Text(e.mensagem, style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
            ]),
          ),
        if (_temMais)
          Padding(
            padding: EdgeInsets.only(top: t.space3),
            child: OutlinedButton(onPressed: _buscandoMais ? null : _maisAntigos, child: const Text('Mostrar mais')),
          ),
      ]),
    );
  }
}

class _LigarDialogo extends StatelessWidget {
  const _LigarDialogo({required this.script, this.falha});
  final String? script;
  final String? falha;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final s = script;
    return AlertDialog(
      title: const Text('Ligar eventos'),
      content: SingleChildScrollView(
        child: s == null
            ? Text(falha ?? 'Configure NODEBEAT_IP_ORIGEM no servidor',
                style: TradeType.bodyMd.copyWith(color: t.fgSecondary))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Cole no terminal da MK:', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
                SizedBox(height: t.space3),
                SelectableText(s, style: dataStyle(context, TradeType.dataSm)),
              ]),
      ),
      actions: [
        if (s != null)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: s));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Script copiado')));
              }
            },
            child: const Text('Copiar'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
      ],
    );
  }
}

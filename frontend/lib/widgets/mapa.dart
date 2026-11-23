import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'common.dart';
import 'inventario.dart';

/// Mapa de rede da MK: árvore porta -> aparelhos, com busca e filtro "só com problema".
class MapaRedeCard extends StatefulWidget {
  const MapaRedeCard({super.key, required this.api, required this.id});
  final ApiClient api;
  final String id;

  @override
  State<MapaRedeCard> createState() => _MapaRedeCardState();
}

class _MapaRedeCardState extends State<MapaRedeCard> with Carrega<MapaRedeCard, MapaMk> {
  final _busca = TextEditingController();
  Timer? _debounce;
  bool _soProblema = false;
  final _abertas = <String, bool>{}; // escolha do usuário; sem entrada = aberta só se tiver problema

  @override
  Future<MapaMk> buscar() => widget.api.mapa(widget.id, q: _busca.text.trim(), soProblema: _soProblema);

  @override
  void dispose() {
    _debounce?.cancel();
    _busca.dispose();
    super.dispose();
  }

  void _buscaMudou(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), carregar);
  }

  void _erroSnack(Object e) {
    if (!mounted || sessionExpired(context, e)) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e))));
  }

  Future<String?> _pedirTexto(String titulo, String label, String? inicial) {
    final ctl = TextEditingController(text: inicial ?? '');
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(titulo),
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Salvar')),
        ],
      ),
    );
  }

  Future<void> _rotular(MapaPorta p) async {
    final r = await _pedirTexto('Rótulo da porta ${p.nome}', 'Rótulo', p.rotulo);
    if (r == null) return;
    try {
      await widget.api.rotularPorta(widget.id, p.nome, r.isEmpty ? null : r);
      await carregar();
    } catch (e) {
      _erroSnack(e);
    }
  }

  Future<void> _editar(MapaAparelho a) async {
    final ctl = TextEditingController(text: a.apelido ?? '');
    var vigiar = a.vigiado;
    final ok = await showDialog<bool>(
          context: context,
          builder: (c) => StatefulBuilder(
            builder: (c, setS) => AlertDialog(
              title: Text('Aparelho ${a.ip}'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'Apelido')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Vigiar este aparelho'),
                  value: vigiar,
                  onChanged: (v) => setS(() => vigiar = v),
                ),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Salvar')),
              ],
            ),
          ),
        ) ??
        false;
    final apelido = ctl.text.trim();
    if (!ok) return;
    try {
      // apelido vazio limpa (o servidor trata '' como null)
      // só o que mudou: evita fixar vigiar_manual sem o usuário pedir
      final mudouApelido = apelido != (a.apelido ?? '');
      if (!mudouApelido && vigiar == a.vigiado) return;
      await widget.api.editarAparelho(widget.id, a.ip,
          apelido: mudouApelido ? apelido : null, vigiar: vigiar != a.vigiado ? vigiar : null);
      await carregar();
    } catch (e) {
      _erroSnack(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final m = dados;
    final aviso = TradeType.bodyMd.copyWith(color: t.warning);
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Mapa de rede', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        Wrap(spacing: t.space4, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 240,
            child: TextField(
              controller: _busca,
              onChanged: _buscaMudou,
              decoration: const InputDecoration(labelText: 'Buscar aparelho', prefixIcon: Icon(Icons.search, size: 20)),
            ),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(value: _soProblema, onChanged: (v) {
              setState(() => _soProblema = v);
              carregar();
            }),
            SizedBox(width: t.space2),
            Text('só com problema', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          ]),
        ]),
        SizedBox(height: t.space3),
        if (m != null && !m.mkNoAr)
          _aviso(t, Icons.warning_amber_rounded, 'MK fora do ar: estado dos aparelhos desconhecido', aviso),
        if (m != null && m.desatualizado) _aviso(t, Icons.schedule, 'leitura desatualizada', aviso),
        if (erro != null) Text(erro!, style: TradeType.bodyMd.copyWith(color: t.negative)),
        if (m != null && m.portas.isEmpty && erro == null)
          Text('Nenhum aparelho mapeado.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        for (final p in m?.portas ?? const <MapaPorta>[]) _porta(context, t, p),
      ]),
    );
  }

  Widget _aviso(TradeTokens t, IconData icone, String texto, TextStyle estilo) => Padding(
        padding: EdgeInsets.only(bottom: t.space2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icone, size: 16, color: t.warning),
          SizedBox(width: t.space2),
          Expanded(child: Text(texto, style: estilo)),
        ]),
      );

  Widget _porta(BuildContext context, TradeTokens t, MapaPorta p) {
    final aberta = _abertas[p.nome] ?? p.problema;
    final mono = dataStyle(context, TradeType.dataSm);
    final (linkTxt, linkIcone, linkCor) = switch (p.link) {
      'up' => ('link ativo', Icons.link, t.positive),
      'down' => ('link caído', Icons.link_off, t.negative),
      _ => ('link desconhecido', Icons.help_outline, t.fgSecondary),
    };
    final corContador = p.problema ? t.negative : t.fgSecondary;
    return Padding(
      padding: EdgeInsets.only(top: t.space2),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(t.radiusLg),
          border: Border.all(color: p.problema ? t.negative : t.borderSubtle),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.circular(t.radiusLg),
            onTap: () => setState(() => _abertas[p.nome] = !aberta),
            child: Padding(
              padding: EdgeInsets.all(t.space3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(aberta ? Icons.expand_more : Icons.chevron_right, size: 20, color: t.fgSecondary, semanticLabel: aberta ? 'Recolher ${p.nome}' : 'Expandir ${p.nome}'),
                SizedBox(width: t.space2),
                Expanded(
                  child: Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(p.nome, style: mono.copyWith(color: t.fgPrimary)),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(linkIcone, size: 16, color: linkCor),
                      SizedBox(width: t.space1),
                      Text(linkTxt, style: TradeType.label.copyWith(color: linkCor)),
                    ]),
                    Text('${p.noAr}/${p.vigiados} no ar', style: mono.copyWith(color: corContador)),
                    if (p.causa != null && p.causa!.isNotEmpty)
                      Text(p.causa!, style: TradeType.bodyMd.copyWith(color: t.negative)),
                  ]),
                ),
                TextButton(
                  onPressed: () => _rotular(p),
                  child: Text(p.rotulo?.isNotEmpty == true ? p.rotulo! : 'rotular', semanticsLabel: 'Editar rótulo da porta ${p.nome}'),
                ),
              ]),
            ),
          ),
          if (aberta)
            for (final a in p.aparelhos) _aparelho(context, t, a),
        ]),
      ),
    );
  }

  Widget _aparelho(BuildContext context, TradeTokens t, MapaAparelho a) {
    final mono = dataStyle(context, TradeType.dataSm);
    final (txt, icone, cor) = switch (a.estado) {
      'no_ar' => ('No ar', Icons.check_circle_outline, t.positive),
      'offline' => ('OFFLINE', Icons.error_outline, t.negative),
      'nao_vigiado' => ('Não vigiado', Icons.visibility_off_outlined, t.fgSecondary),
      _ => ('Sem informação', Icons.help_outline, t.fgSecondary),
    };
    final nome = (a.apelido?.isNotEmpty == true ? a.apelido : a.nome)?.trim();
    final titulo = nome?.isNotEmpty == true ? nome! : '${a.fabricante ?? 'Aparelho'} ${a.ip}';
    final visto = a.estado == 'offline' ? _vistoHa(a.desde) : '';
    return InkWell(
      onTap: () => _editar(a),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: t.space3, vertical: t.space2),
        child: Wrap(spacing: t.space3, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icone, size: 16, color: cor),
            SizedBox(width: t.space1),
            Text(txt, style: TradeType.label.copyWith(color: cor)),
          ]),
          Text(titulo, style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
          Text(a.ip, style: mono),
          if (a.mac != null) Text(a.mac!, style: mono.copyWith(color: t.fgSecondary)),
          if (a.fabricante != null && nome?.isNotEmpty == true)
            Text(a.fabricante!, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          if (a.eSwitch) Selo('switch', t.info),
          if (a.portaDesconhecida) Selo('porta desconhecida', t.warning),
          if (visto.isNotEmpty) Text(visto, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        ]),
      ),
    );
  }

  String _vistoHa(String? desde) {
    final d = desde == null ? null : DateTime.tryParse(desde);
    if (d == null) return '';
    return 'visto no ar há ${formatDuration(DateTime.now().difference(d).inSeconds.clamp(0, 1 << 30))}';
  }
}

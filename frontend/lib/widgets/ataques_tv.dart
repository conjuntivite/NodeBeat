import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'bandeira.dart';
import 'common.dart';
import 'graficos.dart';
import 'mapa_ataques.dart' show corVia;

/// Lista ao vivo embaixo do mapa da TV: as tentativas mais recentes, a mais nova no topo.
class ListaAoVivo extends StatelessWidget {
  const ListaAoVivo({super.key, required this.recentes});
  final List<Ataque> recentes;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final corpo = TradeType.bodyMd.copyWith(color: t.fgPrimary);
    Widget linha(Ataque a) {
      final h = a.quando.toLocal();
      return Padding(
        padding: EdgeInsets.symmetric(vertical: t.space1),
        child: Row(children: [
          SizedBox(
            width: 80,
            child: Text('${two(h.hour)}:${two(h.minute)}:${two(h.second)}',
                style: dataStyle(context, TradeType.dataSm).copyWith(color: t.fgMuted)),
          ),
          SizedBox(
            width: 64,
            child: Text(a.via.toUpperCase(), style: corpo.copyWith(color: corVia(t, a.via), fontWeight: FontWeight.w500)),
          ),
          SizedBox(
            width: 40,
            child: a.n > 1 ? Text('×${a.n}', style: dataStyle(context, TradeType.dataSm).copyWith(color: t.fgSecondary)) : null,
          ),
          Expanded(
            flex: 3,
            child: Row(children: [
              Bandeira(a.pais),
              SizedBox(width: t.space2),
              Flexible(child: Text(a.paisNome ?? a.pais ?? '?', overflow: TextOverflow.ellipsis, style: corpo)),
              SizedBox(width: t.space2),
              Flexible(
                  child: Text(a.ip,
                      overflow: TextOverflow.ellipsis, style: dataStyle(context, TradeType.dataSm).copyWith(color: t.fgSecondary))),
            ]),
          ),
          Text('→', style: corpo.copyWith(color: t.fgMuted)),
          SizedBox(width: t.space2),
          Expanded(flex: 2, child: Text(a.mkNome, overflow: TextOverflow.ellipsis, style: corpo)),
          Flexible(child: a.sucesso ? Pilula('Acesso aceito', cor: t.negative) : Pilula('Tentativa', cor: t.fgMuted)),
        ]),
      );
    }

    return Container(
      padding: EdgeInsets.all(t.space4),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.borderSubtle))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        eyebrow('Ataques em tempo real', cor: t.fgSecondary),
        SizedBox(height: t.space2),
        if (recentes.isEmpty)
          Text('Aguardando tentativas', style: TradeType.bodySm.copyWith(color: t.fgMuted))
        else
          for (final a in recentes) linha(a),
      ]),
    );
  }
}

/// Coluna à direita da TV: tops das últimas 24 h (painel de Acesso).
class ColunaTops extends StatelessWidget {
  const ColunaTops({super.key, required this.acesso});
  final BlocoPainel acesso;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    Widget bloco(String titulo, Widget corpo) => Padding(
          padding: EdgeInsets.only(bottom: t.space6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            eyebrow(titulo, cor: t.fgSecondary),
            Text('últimas 24 h', style: TradeType.bodySm.copyWith(color: t.fgMuted)),
            SizedBox(height: t.space2),
            corpo,
          ]),
        );
    Widget item(String? cc, String nome, int n) => Padding(
          padding: EdgeInsets.symmetric(vertical: t.space1),
          child: Row(children: [
            Bandeira(cc),
            SizedBox(width: t.space2),
            Expanded(child: Text(nome, overflow: TextOverflow.ellipsis, style: TradeType.bodyMd.copyWith(color: t.fgPrimary))),
            Text('$n', style: dataStyle(context, TradeType.dataSm)),
          ]),
        );
    final vias = acesso.porVia.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Container(
      decoration: BoxDecoration(border: Border(left: BorderSide(color: t.borderSubtle))),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(t.space4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          bloco('Top tentativas', Column(children: [
            for (final c in acesso.topIps.take(5)) item(c.pais, c.ip, c.n),
          ])),
          bloco('Top países', Column(children: [
            for (final p in acesso.topPaises.take(5))
              item(p['pais'] as String?, '${p['pais_nome'] ?? p['pais'] ?? '?'}', (p['n'] as num?)?.toInt() ?? 0),
          ])),
          bloco('Top tipos de acesso', GraficoBarras(dados: [for (final e in vias.take(5)) (e.key.toUpperCase(), e.value)])),
        ]),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../ataques/aba.dart';
import '../ataques/fila.dart';
import '../ataques/geo.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import 'ataques_tv.dart';
import 'common.dart';

// Contorno dos continentes, lido uma vez por página.
// rootBundle.load + utf8 (loadString usaria compute(), que trava no teste).
final Future<List<List<Offset>>> _terra = rootBundle.load('assets/ataques/terra.json').then((d) => [
      for (final p in jsonDecode(utf8.decode(d.buffer.asUint8List())) as List)
        [for (final c in p as List) Offset((c[0] as num).toDouble(), (c[1] as num).toDouble())],
    ]);

typedef _Aviso = ({String mk, String? usuario, String ip, String via, String quando, String? pais});

// "Ciente" vale para a aba inteira: sobrevive a fechar e reabrir o mapa.
final _cientes = <String>{};

// faixas de login aceito empilhadas no topo; acima disso vira "+N outros" para não espremer o mapa
const _faixasMax = 2;

String _chave(_Aviso a) => '${a.mk}|${a.ip}|${a.usuario}|${a.quando}';
String _utc(String iso) => DateTime.parse(iso).toUtc().toIso8601String();

class MapaAtaques extends StatefulWidget {
  const MapaAtaques({
    super.key,
    required this.api,
    this.tv = false,
    this.aoExpirarSessao,
    this.intervalo = const Duration(seconds: 5),
    this.intervaloRodape = const Duration(seconds: 60),
    this.visivel = abaVisivel,
  });
  final ApiClient api;
  final bool tv;
  final VoidCallback? aoExpirarSessao;
  final Duration intervalo, intervaloRodape;
  final bool Function() visivel; // aba oculta: não consulta

  @override
  State<MapaAtaques> createState() => MapaAtaquesState();
}

class MapaAtaquesState extends State<MapaAtaques> with SingleTickerProviderStateMixin {
  final _fila = FilaAtaques();
  final _quadro = ValueNotifier(0);
  final _t0 = DateTime.now();
  late final Ticker _ticker;
  Duration _decorrido = Duration.zero, _ultimoOk = Duration.zero;
  Timer? _timerFeed, _timerPainel;
  String? _cursor;
  bool _buscando = false, _expirou = false;
  int _ultimasLinhas = 0, _descServidor = 0;
  List<List<Offset>> _poligonos = const [];
  BlocoPainel? _acesso;
  List<_Aviso> _avisosPainel = const [];
  final _avisosFeed = <String, _Aviso>{};
  List<Ataque> _recentes = const [];
  final _rotulos = <String>[];
  final _textos = <String, TextPainter>{};

  // Relógio do ticker: avança com os quadros (e com o pump nos testes).
  DateTime get _agora => _t0.add(_decorrido);

  @visibleForTesting
  int get linhasAtivas => _fila.ativas(_agora).length;
  @visibleForTesting
  List<String> get rotulosDesenhados => _rotulos;
  /// Lista ao vivo da TV: mais novo primeiro, no máximo 8.
  @visibleForTesting
  List<Ataque> get recentes => _recentes;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      _decorrido = d;
      final n = linhasAtivas;
      if (n > 0 || _ultimasLinhas > 0) _quadro.value++;
      _ultimasLinhas = n;
    })..start();
    _terra.then((p) {
      if (mounted) setState(() => _poligonos = p);
    }, onError: (_) {}); // sem contorno, o mapa segue só com as linhas
    _feed();
    _painel();
    _timerFeed = Timer.periodic(widget.intervalo, (_) {
      setState(() {}); // atualiza o indicador mesmo com a consulta presa
      _feed();
    });
    _timerPainel = Timer.periodic(widget.intervaloRodape, (_) => _painel());
  }

  @override
  void dispose() {
    _timerFeed?.cancel();
    _timerPainel?.cancel();
    _ticker.dispose();
    _quadro.dispose();
    for (final p in _textos.values) {
      p.dispose();
    }
    super.dispose();
  }

  // 401 avisa uma vez e para as consultas; o resto só deixa o indicador velho.
  bool _sessao(Object e) {
    if (e is! ApiError || e.status != 401) return false;
    if (!_expirou) {
      _expirou = true;
      _timerFeed?.cancel();
      _timerPainel?.cancel();
      widget.aoExpirarSessao?.call();
    }
    return true;
  }

  Future<void> _feed() async {
    if (_buscando || _expirou || !widget.visivel()) return;
    _buscando = true;
    try {
      final r = await widget.api.ataques(desde: _cursor).timeout(widget.intervalo * 3); // 1ª sem cursor: começa do agora
      if (!mounted) return;
      _cursor = r.cursor;
      _descServidor = r.descartados;
      _fila.receber(r.ataques, _agora, janela: widget.intervalo);
      // só o lote novo é ordenado (sort não é estável); o cursor garante que é mais novo que o já visto
      _recentes = [...([...r.ataques]..sort((a, b) => b.quando.compareTo(a.quando))), ..._recentes].take(8).toList();
      final limite = DateTime.now().toUtc().subtract(const Duration(hours: 24));
      _avisosFeed.removeWhere((_, a) => DateTime.parse(a.quando).isBefore(limite));
      for (final a in r.ataques.where((a) => a.sucesso)) {
        final v = (mk: a.mkNome, usuario: a.usuario, ip: a.ip, via: a.via, quando: a.quando.toUtc().toIso8601String(), pais: a.paisNome);
        _avisosFeed[_chave(v)] = v;
      }
      setState(() => _ultimoOk = _decorrido);
    } catch (e) {
      _sessao(e);
    } finally {
      _buscando = false;
    }
  }

  Future<void> _painel() async {
    if (_expirou || !widget.visivel()) return;
    try {
      final b = (await widget.api.painelEventos('24h').timeout(widget.intervaloRodape) /* painel leva ~12 s com cache frio */).blocos['acesso'];
      if (!mounted) return;
      setState(() {
        _acesso = b;
        _avisosPainel = [
          for (final l in b?.loginsExternos ?? const <Map<String, dynamic>>[])
            (mk: '${l['nome']}', usuario: l['usuario'], ip: '${l['ip']}', via: '${l['via']}', quando: _utc(l['quando']), pais: l['pais_nome']),
        ];
      });
    } catch (e) {
      _sessao(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final avisos = <String, _Aviso>{for (final a in [..._avisosPainel, ..._avisosFeed.values]) _chave(a): a}
      ..removeWhere((k, _) => _cientes.contains(k));
    final parado = _decorrido - _ultimoOk;
    final descartados = _fila.descartados + _descServidor; // do último lote: fila + servidor
    final mapa = Stack(children: [
      Positioned.fill(
        child: Center(
          child: AspectRatio(
            aspectRatio: 360 / 142,
            child: Stack(fit: StackFit.expand, children: [
              RepaintBoundary(child: CustomPaint(painter: _Terra(_poligonos, t.bgHover, t.borderSubtle))),
              RepaintBoundary(child: CustomPaint(painter: _Linhas(_fila, () => _agora, t, _quadro, _textos, _rotulos))),
            ]),
          ),
        ),
      ),
      Positioned(
        left: t.space4,
        top: t.space4,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          eyebrow('Todas as MKs, ao vivo', cor: t.fgSecondary),
          SizedBox(height: t.space2),
          Wrap(spacing: t.space3, children: [
            for (final v in viasAtaque)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: corVia(t, v), shape: BoxShape.circle)),
                SizedBox(width: t.space1),
                Text(v.toUpperCase(), style: TradeType.bodySm.copyWith(color: t.fgSecondary)),
              ]),
          ]),
        ]),
      ),
      Positioned(
        right: t.space4,
        top: t.space4,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          // ataques do último lote que não viraram linha (teto da fila ou do servidor)
          if (descartados > 0) ...[
            Text('+$descartados', style: dataStyle(context, TradeType.dataSm).copyWith(color: t.fgMuted)),
            SizedBox(width: t.space2),
          ],
          parado > const Duration(seconds: 30)
              ? Pilula('sem dados há ${formatDuration(parado.inSeconds)}', cor: t.warning, ponto: true)
              // ponto desenhado pela Pilula: o "●" não existe na Poppins e o build não baixa fonte de fora
              : Pilula('ao vivo', cor: t.positive, ponto: true),
        ]),
      ),
      Positioned(
        right: t.space4,
        bottom: t.space2,
        child: Text('IP data by DB-IP', style: TradeType.bodySm.copyWith(color: t.fgMuted)),
      ),
    ]);
    // mais recentes primeiro (ISO em UTC ordena como texto); 2 viram faixa, o resto um resumo
    final ordem = avisos.entries.toList()..sort((x, y) => y.value.quando.compareTo(x.value.quando));
    final resto = ordem.length - _faixasMax;
    Widget centroDe(double alturaTotal) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in ordem.take(_faixasMax)) _faixa(t, e.key, e.value),
      if (resto > 0) _resumo(t, resto, ordem.map((e) => e.key)),
      Expanded(child: mapa),
      // rolagem desligada: em TV baixa as linhas mais antigas são cortadas e o mapa não colapsa
      if (widget.tv)
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: alturaTotal * 0.4),
          child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: ListaAoVivo(recentes: _recentes)),
        ),
    ]);
    final centro = LayoutBuilder(builder: (_, c) => centroDe(c.maxHeight));
    // TV: lista ao vivo embaixo do mapa e tops de 24 h à direita (layout do FortiGuard)
    return ColoredBox(
      color: t.bgSurface,
      child: widget.tv
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: centro),
              SizedBox(width: 360, child: _acesso == null ? const ColunaTopsVazia() : ColunaTops(acesso: _acesso!)),
            ])
          : centro,
    );
  }

  Widget _faixa(TradeTokens t, String chave, _Aviso a) => Container(
        margin: EdgeInsets.fromLTRB(t.space4, t.space2, t.space4, 0),
        padding: EdgeInsets.symmetric(horizontal: t.space4, vertical: t.space2),
        decoration: BoxDecoration(
          color: t.negativeBg,
          border: Border.all(color: t.negative),
          borderRadius: BorderRadius.circular(t.radiusMd),
        ),
        child: Row(children: [
          Icon(Icons.warning_amber_outlined, size: 20, color: t.negative),
          SizedBox(width: t.space3),
          Expanded(
            child: Text(
              'Login de fora aceito: ${a.mk} · ${a.usuario ?? '?'} · ${a.ip}'
              '${a.pais == null ? '' : ' · ${a.pais}'} · ${a.via.toUpperCase()} · ${formatDateTime(a.quando)}',
              style: TradeType.bodyMd.copyWith(color: t.negative, fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(onPressed: () => setState(() => _cientes.add(chave)), child: const Text('Ciente')),
        ]),
      );

  Widget _resumo(TradeTokens t, int n, Iterable<String> chaves) => Container(
        margin: EdgeInsets.fromLTRB(t.space4, t.space2, t.space4, 0),
        padding: EdgeInsets.symmetric(horizontal: t.space4, vertical: t.space1),
        decoration: BoxDecoration(
          border: Border.all(color: t.negative),
          borderRadius: BorderRadius.circular(t.radiusMd),
        ),
        child: Row(children: [
          Expanded(
            child: Text(n == 1 ? '+1 outro login de fora aceito' : '+$n outros logins de fora aceitos',
                style: TradeType.bodySm.copyWith(color: t.negative)),
          ),
          TextButton(onPressed: () => setState(() => _cientes.addAll(chaves)), child: const Text('Ciente em todos')),
        ]),
      );
}

// Camada estática: só repinta quando muda o contorno ou o tema.
class _Terra extends CustomPainter {
  _Terra(this.poligonos, this.preenche, this.borda);
  final List<List<Offset>> poligonos;
  final Color preenche, borda;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (final p in poligonos) {
      path.addPolygon([for (final c in p) projetar(c.dy, c.dx, size)], true);
    }
    canvas.drawPath(path, Paint()..color = preenche);
    canvas.drawPath(path, Paint()
      ..color = borda
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_Terra o) => o.poligonos != poligonos || o.preenche != preenche || o.borda != borda;
}

// Camada das linhas: repinta a cada quadro do ticker (via [repaint]).
class _Linhas extends CustomPainter {
  _Linhas(this.fila, this.agora, this.t, Listenable repaint, this.textos, this.rotulos) : super(repaint: repaint);
  final FilaAtaques fila;
  final DateTime Function() agora;
  final TradeTokens t;
  final Map<String, TextPainter> textos; // cache por nome + cor
  final List<String> rotulos; // o que foi desenhado no último quadro (testes)

  // Nome da MK centrado acima de [p]; opacidade em 10 degraus para o cache valer.
  void _rotulo(Canvas canvas, String nome, Offset p, double opacidade) {
    final cor = t.fgSecondary.withValues(alpha: (opacidade * 10).round() / 10);
    if (cor.a == 0) return;
    if (textos.length > 300) {
      for (final tp in textos.values) {
        tp.dispose();
      }
      textos.clear();
    }
    final tp = textos.putIfAbsent('$nome|${cor.toARGB32()}', () => TextPainter(
          text: TextSpan(text: nome, style: TradeType.bodySm.copyWith(color: cor)),
          textDirection: TextDirection.ltr,
        )..layout());
    tp.paint(canvas, p - Offset(tp.width / 2, tp.height + 6));
    rotulos.add(nome);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final agora = this.agora();
    final b = projetar(destinoLat, destinoLon, size);
    rotulos.clear();
    final todas = fila.ativas(agora);
    // Paradas no destino, só a mais recente leva o nome da MK (senão os rótulos se sobrepõem).
    LinhaAtiva? cheiaRecente;
    for (final l in todas.where((l) => fase(agora.difference(l.inicio)).cabeca >= 1)) {
      if (cheiaRecente == null || l.inicio.isAfter(cheiaRecente.inicio)) cheiaRecente = l;
    }
    for (final l in todas) {
      final f = fase(agora.difference(l.inicio));
      final a = projetar(l.ataque.lat!, l.ataque.lon!, size);
      final c = controleArco(a, b);
      final cor = (l.ataque.sucesso ? t.negative : corVia(t, l.ataque.via)).withValues(alpha: f.opacidade);
      final passos = (24 * f.cabeca).ceil();
      final path = Path()..moveTo(a.dx, a.dy);
      for (var i = 1; i <= passos; i++) {
        final p = pontoNoArco(a, c, b, f.cabeca * i / passos);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, Paint()
        ..color = cor
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = l.ataque.sucesso ? 3 : 1.5);
      canvas.drawCircle(a, 2, Paint()..color = cor);
      final cabeca = pontoNoArco(a, c, b, f.cabeca);
      if (f.cabeca < 1 || identical(l, cheiaRecente)) _rotulo(canvas, l.ataque.mkNome, cabeca, f.opacidade); // na cabeça; no destino quando cheia
      if (f.cabeca < 1) {
        canvas.drawCircle(cabeca, 3, Paint()..color = cor);
      } else {
        // pulso no destino enquanto a linha está cheia
        final idade = agora.difference(l.inicio) - viagem;
        final k = (idade.inMicroseconds / cheia.inMicroseconds).clamp(0.0, 1.0);
        canvas.drawCircle(b, 4 + 12 * k, Paint()
          ..color = cor.withValues(alpha: f.opacidade * (1 - k))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
      }
    }
    canvas.drawCircle(b, 4, Paint()..color = t.actionPrimary);
  }

  @override
  bool shouldRepaint(_Linhas o) => o.t != t;
}

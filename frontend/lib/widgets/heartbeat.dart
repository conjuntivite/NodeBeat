import 'package:material_ui/material_ui.dart';

import '../theme/theme.dart';

const beatPeriod = Duration(milliseconds: 1200);
const _tile = 80.0; // largura de um batimento, em px
// (posição no batimento 0..1, desvio; negativo sobe). Pico R em 0,5.
const _ecg = [
  (0.0, 0.0), (0.3, 0.0), (0.35, -0.15), (0.4, 0.0), (0.46, 0.0), (0.49, 0.2),
  (0.5, -1.0), (0.53, 0.45), (0.56, 0.0), (0.7, 0.0), (0.76, -0.25), (0.82, 0.0), (1.0, 0.0),
];

double _ecgAt(double u) {
  for (var i = 1; i < _ecg.length; i++) {
    if (u <= _ecg[i].$1) {
      final (x0, y0) = _ecg[i - 1];
      final (x1, y1) = _ecg[i];
      return y0 + (y1 - y0) * (u - x0) / (x1 - x0);
    }
  }
  return 0;
}

class HeartbeatPainter extends CustomPainter {
  HeartbeatPainter({required this.isFlat, required this.color, this.progress = 0});
  final bool isFlat;
  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2, amp = size.height * 0.42;
    final path = Path()..moveTo(0, mid);
    for (var x = 0.0; x <= size.width; x += 1) {
      final u = ((x + progress * _tile) / _tile) % 1;
      path.lineTo(x, isFlat ? mid : mid + _ecgAt(u) * amp);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(HeartbeatPainter o) => o.progress != progress || o.color != color || o.isFlat != isFlat;
}

bool isFora(String status) => const {'offline', 'vpn_caiu', 'erro_acesso'}.contains(status);

/// Linha de batimento da MK. `beat` (0..1 em loop) vem do painel para o traçado
/// andar junto com o bip; sem ele a linha tem animação própria.
class HeartbeatLine extends StatefulWidget {
  const HeartbeatLine({super.key, required this.status, this.alert = false, this.height = 24, this.width = 96, this.beat});
  final String status;
  final bool alert;
  final double height, width;
  final Animation<double>? beat;

  @override
  State<HeartbeatLine> createState() => _HeartbeatLineState();
}

class _HeartbeatLineState extends State<HeartbeatLine> with SingleTickerProviderStateMixin {
  late final AnimationController _own = AnimationController(vsync: this, duration: beatPeriod);

  bool get _moves => widget.status == 'no_ar' && !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.beat == null && _moves) {
      if (!_own.isAnimating) _own.repeat();
    } else {
      _own.stop();
    }
  }

  @override
  void didUpdateWidget(HeartbeatLine old) {
    super.didUpdateWidget(old);
    didChangeDependencies();
  }

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final s = widget.status;
    final color = isFora(s)
        ? t.negative
        : s == 'aguardando'
            ? t.fgMuted
            : widget.alert
                ? t.warning
                : t.positive;
    Widget line(double progress) => CustomPaint(
          size: Size(widget.width, widget.height),
          painter: HeartbeatPainter(isFlat: isFora(s), color: color, progress: progress),
        );
    // Linha parada (fora, aguardando, movimento reduzido) não reconstrói a cada quadro.
    final anim = widget.beat ?? _own;
    return ExcludeSemantics(
      child: _moves ? AnimatedBuilder(animation: anim, builder: (_, _) => line(anim.value)) : line(0),
    );
  }
}

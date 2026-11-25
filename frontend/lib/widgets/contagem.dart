import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../theme/theme.dart';
import '../theme/tokens.g.dart';

/// "Atualiza em N s": contagem até a próxima recarga automática da tela.
/// Recomeça quando [ciclo] muda (a tela recarregou); o toque pede a recarga na hora.
class ContagemAtualizacao extends StatefulWidget {
  const ContagemAtualizacao({super.key, required this.intervalo, required this.ciclo, required this.aoAtualizar});
  final Duration intervalo;
  final int ciclo;
  final VoidCallback aoAtualizar;

  @override
  State<ContagemAtualizacao> createState() => _ContagemAtualizacaoState();
}

class _ContagemAtualizacaoState extends State<ContagemAtualizacao> {
  late int _restante = widget.intervalo.inSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_restante > 0) setState(() => _restante--);
    });
  }

  @override
  void didUpdateWidget(ContagemAtualizacao old) {
    super.didUpdateWidget(old);
    if (old.ciclo != widget.ciclo || old.intervalo != widget.intervalo) _restante = widget.intervalo.inSeconds;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Tooltip(
      message: 'Atualizar agora',
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radiusMd),
        onTap: widget.aoAtualizar,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space2, vertical: t.space1),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: widget.intervalo.inSeconds == 0 ? 0 : _restante / widget.intervalo.inSeconds,
                color: t.bgBrand,
                backgroundColor: t.borderSubtle,
              ),
            ),
            SizedBox(width: t.space2),
            Text('Atualiza em $_restante s',
                style: TradeType.label.copyWith(color: t.fgSecondary, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
      ),
    );
  }
}

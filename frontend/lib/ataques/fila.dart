import '../api/client.dart';

const viagem = Duration(milliseconds: 1500);
const cheia = Duration(milliseconds: 2000);
const sumico = Duration(milliseconds: 1000);
const _total = Duration(milliseconds: 4500);

class LinhaAtiva {
  LinhaAtiva(this.ataque, this.inicio);
  final Ataque ataque;
  final DateTime inicio;
}

// Posição da cabeça (0..1) e opacidade da linha conforme a idade.
({double cabeca, double opacidade}) fase(Duration idade) {
  final us = idade.inMicroseconds;
  final cabeca = (us / viagem.inMicroseconds).clamp(0.0, 1.0);
  final apagar = us - (viagem + cheia).inMicroseconds;
  final op = us < 0 ? 0.0 : (1 - apagar / sumico.inMicroseconds).clamp(0.0, 1.0);
  return (cabeca: cabeca, opacidade: op);
}

class FilaAtaques {
  FilaAtaques({this.teto = 60});
  final int teto;
  final _linhas = <LinhaAtiva>[];
  int _descartados = 0;
  int get descartados => _descartados;

  // Espalha o lote na janela; o que passa do teto é descartado da cauda.
  void receber(List<Ataque> lote, DateTime agora, {Duration janela = const Duration(seconds: 5)}) {
    final com = [for (final a in lote) if (a.lat != null && a.lon != null) a];
    for (var i = 0; i < com.length; i++) {
      if (_linhas.length >= teto) {
        _descartados += com.length - i;
        return;
      }
      _linhas.add(LinhaAtiva(com[i], agora.add(janela * i ~/ com.length)));
    }
  }

  List<LinhaAtiva> ativas(DateTime agora) {
    _linhas.removeWhere((l) => agora.difference(l.inicio) >= _total);
    return [for (final l in _linhas) if (!agora.isBefore(l.inicio)) l];
  }
}

import '../api/client.dart';
import 'audio_stub.dart' if (dart.library.js_interop) 'audio_web.dart' as impl;

enum MonitorSound { flatline, beep, silent }

/// Mesma confirmação do worker: o apito não sai por uma amostra ruim só.
const _confirma = Duration(seconds: 120);

/// Um som só para o painel: alguma MK fora há ≥ 120 s → apito; senão bip por batida.
/// Fora há menos, "aguardando" e lista vazia não apitam; worker parado ou sede fora → silêncio.
MonitorSound soundFor(StatusData s, {DateTime? now}) {
  if (s.mks.isEmpty || !s.dadosOk || !s.sedeOk) return MonitorSound.silent;
  final t = now ?? DateTime.now();
  bool confirmada(MkRow m) {
    final d = m.desde == null ? null : DateTime.tryParse(m.desde!);
    return d == null || t.difference(d) >= _confirma; // sem "desde": não dá para adiar
  }

  if (s.mks.any((m) => const {'offline', 'vpn_caiu', 'erro_acesso'}.contains(m.status) && confirmada(m))) {
    return MonitorSound.flatline;
  }
  return s.mks.any((m) => m.status == 'no_ar') ? MonitorSound.beep : MonitorSound.silent;
}

/// Gerador de tom (Web Audio no navegador, no-op fora dele).
class SoundEngine {
  /// Chamar dentro de um clique: o navegador só libera áudio depois dele.
  void unlock() => impl.unlock();
  bool get isSuspended => impl.isSuspended();
  void beep() => impl.beep();
  void startFlatline() => impl.startFlatline();
  void stop() => impl.stop();
  bool get savedOn => impl.loadPref();
  set savedOn(bool v) => impl.savePref(v);
}

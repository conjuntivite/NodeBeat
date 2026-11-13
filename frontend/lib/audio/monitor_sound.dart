import '../api/client.dart';
import 'audio_stub.dart' if (dart.library.js_interop) 'audio_web.dart' as impl;

enum MonitorSound { flatline, beep, silent }

/// Um som só para o painel: alguma MK fora → apito; senão bip por batida.
/// "aguardando" não conta como fora; lista vazia fica em silêncio.
MonitorSound soundFor(StatusData s) {
  if (s.mks.isEmpty) return MonitorSound.silent;
  if (s.mks.any((m) => const {'offline', 'vpn_caiu', 'erro_acesso'}.contains(m.status))) {
    return MonitorSound.flatline;
  }
  return s.mks.any((m) => m.status == 'no_ar') ? MonitorSound.beep : MonitorSound.silent;
}

/// Gerador de tom (Web Audio no navegador, no-op fora dele).
class SoundEngine {
  /// Chamar dentro de um clique: o navegador só libera áudio depois dele.
  void unlock() => impl.unlock();
  void beep() => impl.beep();
  void startFlatline() => impl.startFlatline();
  void stop() => impl.stop();
  bool get savedOn => impl.loadPref();
  set savedOn(bool v) => impl.savePref(v);
}

import 'package:web/web.dart' as web;

const _key = 'nodebeat.som';
web.AudioContext? _ctx;
web.OscillatorNode? _tone;

web.AudioContext get _c => _ctx ??= web.AudioContext();

void unlock() => _c.resume();

/// Sem clique do usuário o navegador mantém o contexto suspenso (alarme mudo).
bool isSuspended() => _ctx == null || _ctx!.state != 'running';

web.OscillatorNode _osc(double hz, web.AudioNode to) {
  final o = _c.createOscillator()
    ..type = 'sine'
    ..frequency.value = hz;
  o.connect(to);
  return o;
}

void beep() {
  final g = _c.createGain()..gain.value = 0.15;
  g.connect(_c.destination);
  final t = _c.currentTime;
  _osc(880, g)
    ..start(t)
    ..stop(t + 0.12);
}

void startFlatline() {
  if (_tone != null) return;
  final g = _c.createGain()..gain.value = 0.15;
  g.connect(_c.destination);
  _tone = _osc(880, g)..start();
}

void stop() {
  try {
    _tone?.stop();
  } catch (_) {}
  _tone = null;
}

bool loadPref() {
  try {
    return web.window.localStorage.getItem(_key) == '1';
  } catch (_) {
    return false;
  }
}

void savePref(bool on) {
  try {
    web.window.localStorage.setItem(_key, on ? '1' : '0');
  } catch (_) {}
}

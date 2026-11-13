import 'package:flutter_test/flutter_test.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/audio/monitor_sound.dart';

final _now = DateTime.utc(2026, 1, 2, 12);

Map<String, dynamic> _mk(String id, String status, {List<String> alertas = const [], int foraHa = 600}) => {
      'id': id, 'nome': id, 'status': status,
      'desde': _now.subtract(Duration(seconds: foraHa)).toIso8601String(), 'cpu': 1, 'mem': 1, 'uptime': '1h',
      'ifaces_ok': 1, 'ifaces_total': 1, 'alertas': alertas, 'versao': '7.14',
    };

StatusData _s(List<Map<String, dynamic>> mks, {bool sede = true, bool dados = true}) => StatusData.fromJson({
      'resumo': {'no_ar': 0, 'com_alerta': 0, 'fora': 0},
      'fila_pendente': 0, 'sede_ok': sede, 'dados_ok': dados, 'mks': mks,
    });

MonitorSound _som(StatusData s) => soundFor(s, now: _now);

void main() {
  test('1 MK fora entre 3 → apito', () {
    expect(_som(_s([_mk('a', 'no_ar'), _mk('b', 'vpn_caiu'), _mk('c', 'no_ar')])), MonitorSound.flatline);
  });
  test('todas no ar, mesmo com alerta → bip', () {
    expect(_som(_s([_mk('a', 'no_ar'), _mk('b', 'no_ar', alertas: ['CPU alta'])])), MonitorSound.beep);
  });
  test('lista vazia e só aguardando → silêncio', () {
    expect(_som(_s([])), MonitorSound.silent);
    expect(_som(_s([_mk('a', 'aguardando')])), MonitorSound.silent);
  });
  test('apito só depois de 120 s fora; antes conta como não fora', () {
    expect(_som(_s([_mk('a', 'no_ar'), _mk('b', 'offline', foraHa: 119)])), MonitorSound.beep);
    expect(_som(_s([_mk('b', 'offline', foraHa: 30)])), MonitorSound.silent);
    expect(_som(_s([_mk('a', 'no_ar'), _mk('b', 'offline', foraHa: 120)])), MonitorSound.flatline);
  });
  test('worker parado ou sede fora → silêncio', () {
    final mks = [_mk('a', 'no_ar'), _mk('b', 'offline')];
    expect(_som(_s(mks, dados: false)), MonitorSound.silent);
    expect(_som(_s(mks, sede: false)), MonitorSound.silent);
  });
}

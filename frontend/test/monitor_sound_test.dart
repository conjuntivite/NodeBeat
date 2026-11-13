import 'package:flutter_test/flutter_test.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/audio/monitor_sound.dart';

Map<String, dynamic> _mk(String id, String status, [List<String> alertas = const []]) => {
      'id': id, 'nome': id, 'status': status, 'desde': null, 'cpu': 1, 'mem': 1, 'uptime': '1h',
      'ifaces_ok': 1, 'ifaces_total': 1, 'alertas': alertas, 'versao': '7.14',
    };

StatusData _s(List<Map<String, dynamic>> mks) => StatusData.fromJson({
      'resumo': {'no_ar': 0, 'com_alerta': 0, 'fora': 0},
      'fila_pendente': 0, 'sede_ok': true, 'mks': mks,
    });

void main() {
  test('1 MK fora entre 3 → apito', () {
    expect(soundFor(_s([_mk('a', 'no_ar'), _mk('b', 'vpn_caiu'), _mk('c', 'no_ar')])), MonitorSound.flatline);
  });
  test('todas no ar, mesmo com alerta → bip', () {
    expect(soundFor(_s([_mk('a', 'no_ar'), _mk('b', 'no_ar', ['CPU alta'])])), MonitorSound.beep);
  });
  test('lista vazia e só aguardando → silêncio', () {
    expect(soundFor(_s([])), MonitorSound.silent);
    expect(soundFor(_s([_mk('a', 'aguardando')])), MonitorSound.silent);
  });
}

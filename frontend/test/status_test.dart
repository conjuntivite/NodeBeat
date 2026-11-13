import 'package:flutter_test/flutter_test.dart';
import 'package:nodebeat/api/client.dart';

void main() {
  test('StatusData lê o JSON de /api/status', () {
    final s = StatusData.fromJson({
      'resumo': {'no_ar': 1, 'com_alerta': 1, 'fora': 0},
      'fila_pendente': 2,
      'sede_ok': false,
      'mks': [
        {
          'id': 'a', 'nome': 'Alfa', 'status': 'no_ar', 'desde': '2026-01-01T10:00:00-03:00',
          'cpu': 91.5, 'mem': 40, 'uptime': '1d2h', 'ifaces_ok': 1, 'ifaces_total': 2,
          'alertas': ['CPU alta (92%)'], 'versao': '7.14',
        },
        {
          'id': 'b', 'nome': 'Beta', 'status': 'aguardando', 'desde': null, 'cpu': null, 'mem': null,
          'uptime': null, 'ifaces_ok': 0, 'ifaces_total': 0, 'alertas': [], 'versao': null,
        },
      ],
    });
    expect(s.sedeOk, false);
    expect(s.filaPendente, 2);
    expect(s.comAlerta, 1);
    expect(s.mks[0].cpu, 91.5);
    expect(s.mks[0].mem, 40.0);
    expect(s.mks[0].alertas, ['CPU alta (92%)']);
    expect(s.mks[1].status, 'aguardando');
    expect(s.mks[1].cpu, isNull);
  });
}

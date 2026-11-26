import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/ataques/fila.dart';
import 'package:nodebeat/ataques/geo.dart';

Ataque _a({double? lat = 10, double? lon = 20, int n = 1}) => Ataque(
      ip: '203.0.113.9', lat: lat, lon: lon, mkNome: 'mk', via: 'ssh', n: n, sucesso: false,
      quando: DateTime.utc(2026, 11, 25),
    );

void main() {
  final t0 = DateTime.utc(2026, 11, 25, 12);

  test('ataqueFromJson', () {
    final a = Ataque.fromJson({
      'ip': '1.2.3.4', 'pais': 'CN', 'pais_nome': 'China', 'lat': 31.2, 'lon': 121.4,
      'mk_nome': 'MK1', 'via': 'ssh', 'n': 3, 'sucesso': true,
      'quando': '2026-11-25T12:00:00+00:00', 'usuario': 'admin',
    });
    expect(a.ip, '1.2.3.4');
    expect(a.paisNome, 'China');
    expect(a.lat, 31.2);
    expect(a.n, 3);
    expect(a.sucesso, true);
    expect(a.usuario, 'admin');
    expect(a.quando.toUtc(), DateTime.utc(2026, 11, 25, 12));
    final b = Ataque.fromJson({
      'ip': '1.2.3.4', 'pais': null, 'pais_nome': null, 'lat': null, 'lon': null,
      'mk_nome': 'MK1', 'via': 'ssh', 'n': 1, 'sucesso': false, 'quando': '2026-11-25T12:00:00Z',
    });
    expect(b.lat, isNull);
    expect(b.usuario, isNull);
  });

  test('projetaCantos', () {
    const s = Size(360, 142);
    expect(projetar(84, -180, s), const Offset(0, 0));
    expect(projetar(-58, 180, s), const Offset(360, 142));
  });

  test('arcoComecaETermina', () {
    const a = Offset(10, 80), b = Offset(300, 100);
    final c = controleArco(a, b);
    expect(pontoNoArco(a, c, b, 0), a);
    expect(pontoNoArco(a, c, b, 1), b);
    expect(c.dy < min(a.dy, b.dy), true);
  });

  test('faseViagemCheiaSumico', () {
    expect(fase(Duration.zero).cabeca, 0);
    final v = fase(const Duration(milliseconds: 1500));
    expect(v.cabeca, 1);
    expect(v.opacidade, 1);
    expect(fase(const Duration(milliseconds: 3500)).opacidade, 1);
    expect(fase(const Duration(milliseconds: 4500)).opacidade, 0);
  });

  test('filaEspalhaNaJanela', () {
    final f = FilaAtaques()..receber([for (var i = 0; i < 5; i++) _a()], t0);
    expect(f.ativas(t0).length, 1);
    expect(f.ativas(t0.add(const Duration(seconds: 4))).length, 5);
  });

  test('filaIgnoraSemCoordenada', () {
    final f = FilaAtaques()..receber([_a(lat: null)], t0);
    expect(f.ativas(t0.add(const Duration(seconds: 1))), isEmpty);
  });

  test('filaRespeitaTeto', () {
    final f = FilaAtaques(teto: 60)..receber([for (var i = 0; i < 100; i++) _a()], t0);
    expect(f.ativas(t0.add(const Duration(seconds: 5))).length <= 60, true);
    expect(f.descartados, 40);
  });

  test('filaReceberLimpaExpiradas', () {
    // sem chamar ativas() (ticker parado), as expiradas não podem ocupar o teto
    final f = FilaAtaques(teto: 2)..receber([_a(), _a()], t0);
    f.receber([_a()], t0.add(const Duration(seconds: 20)));
    expect(f.descartados, 0);
    expect(f.ativas(t0.add(const Duration(seconds: 20))).length, 1);
  });

  test('filaRemoveTerminadas', () {
    final f = FilaAtaques()..receber([_a(), _a()], t0);
    final fim = t0.add(const Duration(seconds: 5, milliseconds: 4501));
    expect(f.ativas(fim), isEmpty);
    expect(f.ativas(t0), isEmpty);
  });

  test('apiAtaquesUsaCursor', () async {
    final urls = <Uri>[];
    final api = ApiClient(
      client: MockClient((req) async {
        urls.add(req.url);
        return http.Response(jsonEncode({'cursor': 'x', 'ataques': [], 'descartados': 2}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
    final r = await api.ataques(desde: 'abc');
    await api.ataques();
    expect(urls[0].path, '/api/eventos/ataques');
    expect(urls[0].query, 'desde=abc');
    expect(urls[1].query, '');
    expect(r.cursor, 'x');
    expect(r.descartados, 2);
  });
}

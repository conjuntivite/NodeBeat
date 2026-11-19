import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nodebeat/api/client.dart';

Map<String, dynamic> painelJson() => {
      'periodo': '24h',
      'gerado_em': '2026-03-05T15:00:00+00:00',
      'resumo': {'acesso': 12, 'autenticacao': 3, 'vpn': 1, 'erros': 5},
      'serie_hora': [
        {'hora': '2026-03-05T14:00:00+00:00', 'acesso': 2, 'autenticacao': 0, 'vpn': 0, 'erros': 1},
        {'hora': '2026-03-05T15:00:00+00:00', 'acesso': 1, 'autenticacao': 1, 'vpn': 0, 'erros': 0},
      ],
      'blocos': {
        'acesso': {
          'total': 12,
          'por_mk': [
            {'mk_id': 'a', 'nome': 'Alfa', 'n': 9},
            {'mk_id': 'b', 'nome': 'Beta', 'n': 3},
          ],
          'top_ips': [
            {'ip': '203.0.113.9', 'n': 7},
          ],
          'por_via': {'ssh': 10, 'telnet': 2},
          'logins_externos': [
            {'mk_id': 'a', 'nome': 'Alfa', 'usuario': 'admin', 'ip': '203.0.113.9', 'via': 'ssh', 'quando': '2026-03-05T14:00:00+00:00'},
          ],
        },
        'autenticacao': {'total': 3, 'por_mk': [], 'por_subtipo': {'falha_interna': 2, 'login_ok': 4}},
        'vpn': {
          'total': 1,
          'por_mk': [],
          'por_subtipo': {'falha': 1},
          'ultimos': [
            {'mk_id': 'a', 'nome': 'Alfa', 'quando': '2026-03-05T14:00:00+00:00', 'mensagem': 'failed to pre-process ph2 packet.'},
          ],
        },
        'erros': {
          'total': 5,
          'por_mk': [],
          'por_subtipo': {'link_fisico': 5},
          'interfaces': [
            {'mk_id': 'a', 'nome': 'Alfa', 'interface': 'ether3', 'n': 5},
          ],
        },
      },
      'por_mk': [
        {
          'mk_id': 'a',
          'nome': 'Alfa',
          'semaforo': 'vermelho',
          'motivos': ['Login de fora: admin de 203.0.113.9 via ssh'],
          'contagens': {'acesso': 9, 'autenticacao': 0, 'vpn': 1, 'erros': 5},
        },
        {'mk_id': 'b', 'nome': 'Beta', 'semaforo': 'verde', 'motivos': [], 'contagens': {'acesso': 3}},
      ],
      'atencao': [
        {'mk_id': 'a', 'nome': 'Alfa', 'semaforo': 'vermelho', 'motivo': 'Login de fora: admin de 203.0.113.9 via ssh'},
      ],
      'incidentes': [
        {'inicio': '2026-03-05T13:00:00+00:00', 'fim': '2026-03-05T13:10:00+00:00', 'sintoma': 'interface_down', 'mks': ['Alfa', 'Beta', 'Gama']},
      ],
      'config': [
        {
          'mk_id': 'a',
          'nome': 'Alfa',
          'quando': '2026-03-05T01:00:00+00:00',
          'usuario': 'fulano',
          'objeto': 'log rule',
          'acao': 'added',
          'fora_horario': true,
          'usuario_novo': true,
        },
      ],
    };

void main() {
  test('PainelEventos.fromJson lê resumo, semáforo, blocos, incidentes e mudanças', () {
    final p = PainelEventos.fromJson(painelJson());
    expect(p.periodo, '24h');
    expect(p.resumo['acesso'], 12);
    expect(p.serieHora.length, 2);
    expect(p.serieHora.first.valores['acesso'], 2);
    expect(p.porMk.first.semaforo, 'vermelho');
    expect(p.porMk.first.motivos.first, startsWith('Login de fora'));
    expect(p.porMk.last.contagens['acesso'], 3);
    final acesso = p.blocos['acesso']!;
    expect(acesso.total, 12);
    expect(acesso.topIps.first.ip, '203.0.113.9');
    expect(acesso.topIps.first.n, 7);
    expect(acesso.porVia['ssh'], 10);
    expect(acesso.porMk.first.nome, 'Alfa');
    expect(acesso.loginsExternos.first['usuario'], 'admin');
    expect(p.blocos['erros']!.interfaces.first['interface'], 'ether3');
    expect(p.blocos['vpn']!.ultimos.first['mensagem'], contains('ph2'));
    expect(p.atencao.first.motivo, startsWith('Login de fora'));
    expect(p.incidentes.first.mks, ['Alfa', 'Beta', 'Gama']);
    expect(p.config.first.foraHorario, true);
    expect(p.config.first.usuarioNovo, true);
  });

  test('painelEventos chama /api/eventos/painel com periodo e mk', () async {
    final urls = <Uri>[];
    final api = ApiClient(
      client: MockClient((req) async {
        urls.add(req.url);
        return http.Response(jsonEncode(painelJson()), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
    await api.painelEventos('7d', mkId: 'x');
    await api.painelEventos('24h');
    expect(urls[0].path, '/api/eventos/painel');
    expect(urls[0].queryParameters, {'periodo': '7d', 'mk': 'x'});
    expect(urls[1].queryParameters, {'periodo': '24h'});
  });
}

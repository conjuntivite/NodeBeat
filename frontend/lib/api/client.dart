import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiError implements Exception {
  ApiError(this.message, [this.status, this.fields = const {}]);
  final String message;
  final int? status;

  /// Erros 422 por campo (último item de `loc` -> mensagem), quando o servidor os envia.
  final Map<String, String> fields;
  @override
  String toString() => message;
}

class MkRow {
  MkRow.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        nome = j['nome'],
        status = j['status'],
        desde = j['desde'],
        cpu = (j['cpu'] as num?)?.toDouble(),
        mem = (j['mem'] as num?)?.toDouble(),
        uptime = j['uptime'],
        ifacesOk = j['ifaces_ok'],
        ifacesTotal = j['ifaces_total'],
        alertas = List<String>.from(j['alertas']),
        versao = j['versao'];
  final String id, nome;

  /// no_ar | offline | vpn_caiu | erro_acesso | aguardando
  final String status;
  final String? desde, uptime, versao;
  final double? cpu, mem;
  final int ifacesOk, ifacesTotal;
  final List<String> alertas;
}

class StatusData {
  StatusData.fromJson(Map<String, dynamic> j)
      : noAr = j['resumo']['no_ar'],
        comAlerta = j['resumo']['com_alerta'],
        fora = j['resumo']['fora'],
        filaPendente = j['fila_pendente'],
        sedeOk = j['sede_ok'],
        dadosOk = j['dados_ok'] == true,
        mks = [for (final m in j['mks']) MkRow.fromJson(m)];
  final int noAr, comAlerta, fora, filaPendente;
  final bool sedeOk;

  /// false = worker parado (dados velhos).
  final bool dadosOk;
  final List<MkRow> mks;
}

/// Estado atual guardado pelo worker; null em MkDetail se a MK ainda não foi lida.
class MkEstado {
  MkEstado.fromJson(Map<String, dynamic> j)
      : status = j['status'],
        detalhe = j['detalhe'],
        desde = j['desde'],
        cpu = (j['cpu'] as num?)?.toDouble(),
        mem = (j['mem'] as num?)?.toDouble(),
        uptime = j['uptime'],
        ifaces = Map<String, bool>.from(j['ifaces'] ?? {}),
        versao = j['versao'],
        atualizadoEm = j['atualizado_em'];
  final String status;
  final String? detalhe, desde, uptime, versao, atualizadoEm;
  final double? cpu, mem;
  final Map<String, bool> ifaces;
}

class MkDetail {
  MkDetail.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        nome = j['nome'],
        ipTunel = j['ip_tunel'],
        ipPublico = j['ip_publico'],
        usuario = j['usuario'],
        interfacesVigiadas = List<String>.from(j['interfaces_vigiadas'] ?? []),
        certSha256 = j['cert_sha256'],
        estado = j['estado'] == null ? null : MkEstado.fromJson(j['estado']);
  final String id, nome, ipTunel, ipPublico, usuario;
  final List<String> interfacesVigiadas;
  final String? certSha256;
  final MkEstado? estado;
}

class MkInput {
  MkInput({required this.nome, required this.ipTunel, required this.ipPublico, required this.usuario, this.senha});
  final String nome, ipTunel, ipPublico, usuario;

  /// null na edição = manter a senha atual (o campo não é enviado).
  final String? senha;
  Map<String, dynamic> toJson() => {
        'nome': nome, 'ip_tunel': ipTunel, 'ip_publico': ipPublico, 'usuario': usuario,
        if (senha != null) 'senha': senha,
      };
}

class IfaceInfo {
  IfaceInfo.fromJson(Map<String, dynamic> j)
      : nome = j['nome'],
        running = j['running'];
  final String nome;
  final bool running;
}

class HistEvent {
  HistEvent.fromJson(Map<String, dynamic> j)
      : evento = j['evento'],
        tipo = j['tipo'],
        mkId = j['mk']?['id'],
        mkNome = j['mk']?['nome'],
        detalhe = j['detalhe'],
        inicio = j['inicio'],
        fim = j['fim'],
        duracaoS = (j['duracao_s'] as num?)?.toInt();
  final String evento, tipo;
  final String? mkId, mkNome, detalhe, inicio, fim;
  final int? duracaoS;
}

class FaixaRede {
  FaixaRede.fromJson(Map<String, dynamic> j)
      : rede = j['rede'],
        origem = j['origem'],
        interface = j['interface'],
        tunel = j['tunel'] == true;
  final String rede;
  final String? origem, interface;
  final bool tunel;
}

class FaixaMk {
  FaixaMk.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        nome = j['nome'],
        lidoEm = j['lido_em'],
        erro = j['erro'],
        desatualizado = j['desatualizado'] == true,
        redes = [for (final r in j['redes'] ?? []) FaixaRede.fromJson(r)];
  final String id, nome;
  final String? lidoEm, erro;
  final bool desatualizado;
  final List<FaixaRede> redes;
}

class Sobreposicao {
  Sobreposicao.fromJson(Map<String, dynamic> j)
      : a = j['a'],
        redeA = j['rede_a'],
        b = j['b'],
        redeB = j['rede_b'];
  final String a, redeA, b, redeB;
}

class FaixasData {
  FaixasData.fromJson(Map<String, dynamic> j)
      : mks = [for (final m in j['mks']) FaixaMk.fromJson(m)],
        sede = List<String>.from(j['sede'] ?? []),
        sobreposicoes = [for (final s in j['sobreposicoes'] ?? []) Sobreposicao.fromJson(s)];
  final List<FaixaMk> mks;
  final List<String> sede;
  final List<Sobreposicao> sobreposicoes;
}

class IpVisto {
  IpVisto.fromJson(Map<String, dynamic> j)
      : ip = j['ip'],
        mac = j['mac'],
        hostName = j['host_name'],
        fixo = j['fixo'] == true,
        ultimoVisto = j['ultimo_visto'],
        emUso = j['em_uso'] == true;
  final String ip;
  final String? mac, hostName, ultimoVisto;
  final bool fixo, emUso;
}

/// Resposta das conferências de faixa, porta e IP: `resultado` é em_uso | livre | fora_da_faixa | sem_dados.
class Conferencia {
  Conferencia.fromJson(Map<String, dynamic> j)
      : resultado = j['resultado'],
        avisos = List<String>.from(j['avisos'] ?? []),
        faltam = List<String>.from(j['faltam'] ?? []),
        desatualizado = j['desatualizado'] == true,
        colisoes = [for (final c in j['colisoes'] ?? []) '${c['nome']} (${c['rede']})'],
        usos = List<String>.from(j['usos'] ?? []),
        visto = j['visto'] == null ? null : IpVisto.fromJson(j['visto']);
  final String resultado;
  final List<String> avisos, faltam, colisoes, usos;
  final bool desatualizado;
  final IpVisto? visto;
}

class NatRegra {
  NatRegra.fromJson(Map<String, dynamic> j)
      : protocolo = j['protocolo'],
        dstPort = j['dst_port'],
        toAddresses = j['to_addresses'],
        toPorts = j['to_ports'],
        comentario = j['comentario'],
        ativo = j['ativo'] != false,
        aberto = j['aberto'] == true;
  final String? protocolo, dstPort, toAddresses, toPorts, comentario;
  final bool ativo, aberto;
}

class Servico {
  Servico.fromJson(Map<String, dynamic> j)
      : nome = j['nome'],
        porta = j['porta'],
        ativo = j['ativo'] != false,
        aberto = j['aberto'] == true;
  final String nome;
  final Object? porta;
  final bool ativo, aberto;
}

class InventarioMk {
  InventarioMk.fromJson(Map<String, dynamic> j)
      : lidoEm = j['lido_em'],
        erro = j['erro'],
        desatualizado = j['desatualizado'] == true,
        nat = [for (final n in j['nat'] ?? []) NatRegra.fromJson(n)],
        servicos = [for (final s in j['servicos'] ?? []) Servico.fromJson(s)];
  final String? lidoEm, erro;
  final bool desatualizado;
  final List<NatRegra> nat;
  final List<Servico> servicos;
}

class ApiClient {
  ApiClient({http.Client? client, this.base = '/api'}) : _http = client ?? http.Client();
  final http.Client _http;
  final String base;

  // Relativo à origem da página: o navegador envia o cookie de sessão sozinho.
  Uri _uri(String path) => Uri.base.resolve('$base$path');

  Future<dynamic> _send(String method, String path, {Object? body, Map<int, String> erros = const {}}) async {
    final req = http.Request(method, _uri(path));
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await _http.send(req));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    }
    throw ApiError(erros[res.statusCode] ?? _detail(res), res.statusCode, _fields(res));
  }

  Map<String, String> _fields(http.Response res) {
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes))['detail'];
      if (d is List) return {for (final e in d) (e['loc'] as List).last.toString(): e['msg'].toString()};
    } catch (_) {}
    return const {};
  }

  String _detail(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final d = j['detail'] ?? j['detalhe'];
      if (d is String) return d;
      if (d is List) return 'Requisição inválida';
    } catch (_) {}
    return 'Erro ${res.statusCode}';
  }

  Future<void> login(String u, String p) => _send('POST', '/auth/login',
      body: {'usuario': u, 'senha': p},
      erros: {401: 'Usuário ou senha inválidos', 429: 'Muitas tentativas. Aguarde 15 minutos.'});

  Future<void> logout() => _send('POST', '/auth/logout');

  Future<StatusData> status() async => StatusData.fromJson(await _send('GET', '/status'));

  Future<MkDetail> mk(String id) async => MkDetail.fromJson(await _send('GET', '/mks/$id'));

  Future<String> createMk(MkInput i) async => (await _send('POST', '/mks', body: i.toJson()))['id'];

  Future<void> updateMk(String id, MkInput i) => _send('PUT', '/mks/$id', body: i.toJson());

  Future<void> deleteMk(String id) => _send('DELETE', '/mks/$id');

  Future<List<IfaceInfo>> interfaces(String id) async =>
      [for (final j in await _send('GET', '/mks/$id/interfaces')) IfaceInfo.fromJson(j)];

  Future<void> setWatched(String id, List<String> names) =>
      _send('PUT', '/mks/$id/interfaces-vigiadas', body: {'interfaces': names});

  Future<void> acceptCert(String id) => _send('POST', '/mks/$id/aceitar-certificado');

  Future<List<HistEvent>> history(String id) async =>
      [for (final j in await _send('GET', '/mks/$id/historico')) HistEvent.fromJson(j)];

  Future<FaixasData> faixas() async => FaixasData.fromJson(await _send('GET', '/faixas'));

  Future<Conferencia> conferirFaixa(String cidr) async =>
      Conferencia.fromJson(await _send('GET', '/faixas/conferir?cidr=${Uri.encodeQueryComponent(cidr)}'));

  Future<void> pedirAtualizarFaixas() => _send('POST', '/faixas/atualizar');

  Future<InventarioMk> inventario(String id) async => InventarioMk.fromJson(await _send('GET', '/mks/$id/inventario'));

  Future<InventarioMk> atualizarInventario(String id) async =>
      InventarioMk.fromJson(await _send('POST', '/mks/$id/inventario/atualizar'));

  Future<Conferencia> conferirPorta(String id, int porta, String protocolo) async =>
      Conferencia.fromJson(await _send('GET', '/mks/$id/portas/conferir?porta=$porta&protocolo=$protocolo'));

  Future<List<IpVisto>> ips(String id) async =>
      [for (final j in await _send('GET', '/mks/$id/ips')) IpVisto.fromJson(j)];

  Future<Conferencia> conferirIp(String id, String ip) async =>
      Conferencia.fromJson(await _send('GET', '/mks/$id/ips/conferir?ip=${Uri.encodeQueryComponent(ip)}'));

  Future<void> esquecerIp(String id, String ip) => _send('DELETE', '/mks/$id/ips/$ip');
}

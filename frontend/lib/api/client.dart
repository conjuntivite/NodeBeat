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

  /// no_ar | offline | vpn_caiu | erro_acesso | reiniciando | aguardando
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
        semIpsec = j['sem_ipsec'] == true,
        usuario = j['usuario'],
        interfacesVigiadas = List<String>.from(j['interfaces_vigiadas'] ?? []),
        certSha256 = j['cert_sha256'],
        estado = j['estado'] == null ? null : MkEstado.fromJson(j['estado']);
  final String id, nome, ipTunel, ipPublico, usuario;
  final bool semIpsec;
  final List<String> interfacesVigiadas;
  final String? certSha256;
  final MkEstado? estado;
}

class MkInput {
  MkInput({required this.nome, required this.ipTunel, required this.ipPublico, required this.usuario, this.semIpsec = false, this.senha});
  final String nome, ipTunel, ipPublico, usuario;
  final bool semIpsec;

  /// null na edição = manter a senha atual (o campo não é enviado).
  final String? senha;
  Map<String, dynamic> toJson() => {
        'nome': nome, 'ip_tunel': ipTunel, 'ip_publico': ipPublico, 'usuario': usuario, 'sem_ipsec': semIpsec,
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

class PrepararMkInfo {
  PrepararMkInfo.fromJson(Map<String, dynamic> j)
      : ipOrigem = j['ip_origem'],
        ipsSede = List<String>.from(j['ips_publicos_sede'] ?? const []);
  final String? ipOrigem;
  final List<String> ipsSede;
}

class Evento {
  Evento.fromJson(Map<String, dynamic> j)
      : recebidoEm = DateTime.parse(j['recebido_em']),
        severidade = j['severidade'] ?? '',
        tipo = j['tipo'] ?? '',
        mensagem = j['mensagem'] ?? '',
        topicos = List<String>.from(j['topicos'] ?? const []),
        campos = Map<String, dynamic>.from(j['campos'] ?? const {});
  final DateTime recebidoEm;
  final String severidade, tipo, mensagem;
  final List<String> topicos;
  final Map<String, dynamic> campos;
}

class EventosPagina {
  EventosPagina.fromJson(Map<String, dynamic> j)
      : eventos = [for (final e in j['eventos'] ?? const []) Evento.fromJson(e)],
        syslogAtivo = j['syslog_ativo'] ?? false;
  final List<Evento> eventos;
  final bool syslogAtivo;
}

Map<String, int> _mapaInt(Object? m) => {for (final e in (m as Map? ?? const {}).entries) e.key as String: (e.value as num).toInt()};
List<Map<String, dynamic>> _lista(Object? l) => [for (final e in (l as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

class PontoSerie {
  PontoSerie(this.hora, this.valores);
  PontoSerie.fromJson(Map<String, dynamic> j)
      : hora = DateTime.parse(j['hora']),
        valores = {for (final e in j.entries) if (e.key != 'hora') e.key: (e.value as num).toInt()};
  final DateTime hora;
  final Map<String, int> valores;
}

class ContaMk {
  ContaMk.fromJson(Map<String, dynamic> j)
      : mkId = j['mk_id'],
        nome = j['nome'],
        n = (j['n'] as num).toInt();
  final String mkId, nome;
  final int n;
}

class ContaIp {
  ContaIp.fromJson(Map<String, dynamic> j)
      : ip = j['ip'],
        n = (j['n'] as num).toInt();
  final String ip;
  final int n;
}

class BlocoPainel {
  BlocoPainel.fromJson(Map<String, dynamic> j)
      : total = (j['total'] as num).toInt(),
        porMk = [for (final e in _lista(j['por_mk'])) ContaMk.fromJson(e)],
        topIps = [for (final e in _lista(j['top_ips'])) ContaIp.fromJson(e)],
        porVia = _mapaInt(j['por_via']),
        porSubtipo = _mapaInt(j['por_subtipo']),
        loginsExternos = _lista(j['logins_externos']),
        ultimos = _lista(j['ultimos']),
        interfaces = _lista(j['interfaces']);
  final int total;
  final List<ContaMk> porMk;
  final List<ContaIp> topIps;
  final Map<String, int> porVia, porSubtipo;
  final List<Map<String, dynamic>> loginsExternos, ultimos, interfaces;
}

class MkPainel {
  MkPainel.fromJson(Map<String, dynamic> j)
      : mkId = j['mk_id'],
        nome = j['nome'],
        semaforo = j['semaforo'],
        motivos = List<String>.from(j['motivos'] ?? const []),
        contagens = _mapaInt(j['contagens']);
  final String mkId, nome, semaforo;
  final List<String> motivos;
  final Map<String, int> contagens;
}

class AtencaoItem {
  AtencaoItem.fromJson(Map<String, dynamic> j)
      : mkId = j['mk_id'],
        nome = j['nome'],
        semaforo = j['semaforo'],
        motivo = j['motivo'];
  final String mkId, nome, semaforo, motivo;
}

class Incidente {
  Incidente.fromJson(Map<String, dynamic> j)
      : inicio = DateTime.parse(j['inicio']),
        fim = DateTime.parse(j['fim']),
        sintoma = j['sintoma'],
        mks = List<String>.from(j['mks']);
  final DateTime inicio, fim;
  final String sintoma;
  final List<String> mks;
}

class MudancaConfig {
  MudancaConfig.fromJson(Map<String, dynamic> j)
      : mkId = j['mk_id'],
        nome = j['nome'],
        quando = DateTime.parse(j['quando']),
        usuario = j['usuario'],
        objeto = j['objeto'],
        acao = j['acao'],
        foraHorario = j['fora_horario'] == true,
        usuarioNovo = j['usuario_novo'] == true;
  final String mkId, nome;
  final DateTime quando;
  final String? usuario, objeto, acao;
  final bool foraHorario, usuarioNovo;
}

/// Selo e variação de uma categoria: estado = esperado | normal | atencao | critico.
class EstadoCategoria {
  EstadoCategoria.fromJson(Map<String, dynamic> j)
      : estado = j['estado'] as String,
        deltaPct = (j['delta_pct'] as num?)?.toInt();
  final String estado;
  final int? deltaPct; // null: sem base de comparação
}

class PainelEventos {
  PainelEventos.fromJson(Map<String, dynamic> j)
      : periodo = j['periodo'],
        resumo = _mapaInt(j['resumo']),
        resumoEstado = {
          for (final e in (j['resumo_estado'] as Map? ?? const {}).entries)
            e.key as String: EstadoCategoria.fromJson(Map<String, dynamic>.from(e.value)),
        },
        serieHora = [for (final e in _lista(j['serie_hora'])) PontoSerie.fromJson(e)],
        blocos = {for (final e in (j['blocos'] as Map).entries) e.key as String: BlocoPainel.fromJson(Map<String, dynamic>.from(e.value))},
        porMk = [for (final e in _lista(j['por_mk'])) MkPainel.fromJson(e)],
        atencao = [for (final e in _lista(j['atencao'])) AtencaoItem.fromJson(e)],
        incidentes = [for (final e in _lista(j['incidentes'])) Incidente.fromJson(e)],
        config = [for (final e in _lista(j['config'])) MudancaConfig.fromJson(e)];
  final String periodo;
  final Map<String, int> resumo;
  final Map<String, EstadoCategoria> resumoEstado;
  final List<PontoSerie> serieHora;
  final Map<String, BlocoPainel> blocos;
  final List<MkPainel> porMk;
  final List<AtencaoItem> atencao;
  final List<Incidente> incidentes;
  final List<MudancaConfig> config;
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

class MapaAparelho {
  MapaAparelho.fromJson(Map<String, dynamic> j)
      : ip = j['ip'] ?? '',
        mac = j['mac'],
        fabricante = j['fabricante'],
        nome = j['nome'],
        apelido = j['apelido'],
        vigiado = j['vigiado'] == true,
        eSwitch = j['e_switch'] == true,
        estado = j['estado'] ?? 'desconhecido',
        desde = j['desde'],
        ultimoVisto = j['ultimo_visto'],
        portaDesconhecida = j['porta_desconhecida'] == true,
        gerenciavel = j['gerenciavel'] as bool?,
        portas = [for (final p in j['portas'] ?? []) MapaPorta.fromJson(p)],
        snmpErro = j['snmp_erro'] == true,
        switchLidoEm = j['switch_lido_em'],
        dica = j['dica'];
  final String ip, estado;
  final String? mac, fabricante, nome, apelido, desde, ultimoVisto, switchLidoEm, dica;
  final bool vigiado, eSwitch, portaDesconhecida, snmpErro;
  final bool? gerenciavel; // null: campo ausente (não é switch nem candidato)
  final List<MapaPorta> portas; // só switch gerenciável
}

class MapaPorta {
  MapaPorta.fromJson(Map<String, dynamic> j)
      : nome = j['nome'] ?? '',
        rotulo = j['rotulo'],
        link = j['link'] ?? 'desconhecido',
        vigiados = j['vigiados'] ?? 0,
        noAr = j['no_ar'] ?? 0,
        problema = j['problema'] == true,
        causa = j['causa'],
        aparelhos = [for (final a in j['aparelhos'] ?? []) MapaAparelho.fromJson(a)];
  final String nome, link;
  final String? rotulo, causa;
  final int vigiados, noAr;
  final bool problema;
  final List<MapaAparelho> aparelhos;
}

class MapaMk {
  MapaMk.fromJson(Map<String, dynamic> j)
      : lidoEm = j['lido_em'],
        desatualizado = j['desatualizado'] == true,
        mkNoAr = j['mk_no_ar'] != false,
        portas = [for (final p in j['portas'] ?? []) MapaPorta.fromJson(p)];
  final String? lidoEm;
  final bool desatualizado, mkNoAr;
  final List<MapaPorta> portas;
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

  /// Devolve o caminho usado: 'tunel' ou 'publico'.
  Future<String> reiniciar(String id) async => (await _send('POST', '/mks/$id/reiniciar'))['via'] as String;

  Future<List<HistEvent>> history(String id) async =>
      [for (final j in await _send('GET', '/mks/$id/historico')) HistEvent.fromJson(j)];

  Future<FaixasData> faixas() async => FaixasData.fromJson(await _send('GET', '/faixas'));

  Future<Conferencia> conferirFaixa(String cidr) async =>
      Conferencia.fromJson(await _send('GET', '/faixas/conferir?cidr=${Uri.encodeQueryComponent(cidr)}'));

  Future<void> pedirAtualizarFaixas() => _send('POST', '/faixas/atualizar');

  Future<PrepararMkInfo> prepararMk() async => PrepararMkInfo.fromJson(await _send('GET', '/preparar-mk'));

  Future<InventarioMk> inventario(String id) async => InventarioMk.fromJson(await _send('GET', '/mks/$id/inventario'));

  Future<InventarioMk> atualizarInventario(String id) async =>
      InventarioMk.fromJson(await _send('POST', '/mks/$id/inventario/atualizar'));

  Future<Conferencia> conferirPorta(String id, int porta, String protocolo) async =>
      Conferencia.fromJson(await _send('GET', '/mks/$id/portas/conferir?porta=$porta&protocolo=$protocolo'));

  Future<List<IpVisto>> ips(String id) async =>
      [for (final j in await _send('GET', '/mks/$id/ips')) IpVisto.fromJson(j)];

  Future<Conferencia> conferirIp(String id, String ip) async =>
      Conferencia.fromJson(await _send('GET', '/mks/$id/ips/conferir?ip=${Uri.encodeQueryComponent(ip)}'));

  Future<EventosPagina> eventos(String id,
      {List<String> tipos = const [], DateTime? desde, DateTime? ate, String? q, int limite = 200}) async {
    final query = [
      for (final t in tipos) 'tipo=${Uri.encodeQueryComponent(t)}',
      if (desde != null) 'desde=${Uri.encodeQueryComponent(desde.toUtc().toIso8601String())}',
      if (ate != null) 'ate=${Uri.encodeQueryComponent(ate.toUtc().toIso8601String())}',
      if (q != null && q.isNotEmpty) 'q=${Uri.encodeQueryComponent(q)}',
      'limite=$limite',
    ].join('&');
    return EventosPagina.fromJson(await _send('GET', '/mks/$id/eventos?$query'));
  }

  Future<PainelEventos> painelEventos(String periodo, {String? mkId}) async {
    final query = 'periodo=${Uri.encodeQueryComponent(periodo)}${mkId == null ? '' : '&mk=${Uri.encodeQueryComponent(mkId)}'}';
    return PainelEventos.fromJson(await _send('GET', '/eventos/painel?$query'));
  }

  Future<void> esquecerIp(String id, String ip) => _send('DELETE', '/mks/$id/ips/$ip');

  Future<MapaMk> mapa(String id, {String? q, bool soProblema = false}) async {
    final query = [
      if (q != null && q.isNotEmpty) 'q=${Uri.encodeQueryComponent(q)}',
      if (soProblema) 'so_problema=true',
    ].join('&');
    return MapaMk.fromJson(await _send('GET', '/mks/$id/mapa${query.isEmpty ? '' : '?$query'}'));
  }

  /// Só os campos informados vão no corpo (ausente = não mexe).
  Future<void> editarAparelho(String id, String ip, {String? apelido, bool? vigiar, bool? eSwitch}) =>
      _send('PUT', '/mks/$id/mapa/aparelhos/${Uri.encodeComponent(ip)}', body: {
        'apelido': ?apelido,
        'vigiar': ?vigiar,
        'e_switch': ?eSwitch,
      });

  Future<void> rotularPorta(String id, String porta, String? rotulo) =>
      _send('PUT', '/mks/$id/mapa/rotulo-porta', body: {'porta': porta, 'rotulo': rotulo});
}

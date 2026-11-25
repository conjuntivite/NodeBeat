import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../audio/monitor_sound.dart';
import '../sessao.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/contagem.dart';
import '../widgets/heartbeat.dart';
import '../widgets/shell.dart';
import 'switches.dart';

const _refresh = Duration(seconds: 15);

typedef _Col = ({
  String label,
  int flex,
  num Function(MkRow)? num,
  String Function(MkRow)? text,
});

num _uptimeSeconds(String? u) {
  var s = 0;
  for (final m in RegExp(r'(\d+)([wdhms])').allMatches(u ?? '')) {
    s +=
        int.parse(m[1]!) *
        const {'w': 604800, 'd': 86400, 'h': 3600, 'm': 60, 's': 1}[m[2]]!;
  }
  return s;
}

// Fora primeiro, depois alerta, aguardando, no ar.
num _severity(MkRow m) => isFora(m.status)
    ? 0
    : m.alertas.isNotEmpty
    ? 1
    : m.status == 'aguardando'
    ? 2
    : 3;

final _cols = <_Col>[
  (label: 'Condomínio', flex: 3, num: null, text: (m) => m.nome.toLowerCase()),
  (label: 'Status', flex: 3, num: _severity, text: null),
  (label: 'CPU', flex: 1, num: (m) => m.cpu ?? -1, text: null),
  (label: 'Mem', flex: 1, num: (m) => m.mem ?? -1, text: null),
  (label: 'Uptime', flex: 2, num: (m) => _uptimeSeconds(m.uptime), text: null),
  (
    label: 'Interfaces',
    flex: 2,
    num: (m) => m.ifacesTotal == 0 ? 1 : m.ifacesOk / m.ifacesTotal,
    text: null,
  ),
];

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.api, this.sound, this.abrir});
  final ApiClient api;
  final SoundEngine? sound;

  /// Página recarregada dentro de uma MK: o painel fica por baixo (som e voltar) e reabre ela.
  final String? abrir;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  late final SoundEngine _engine = widget.sound ?? SoundEngine();
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: beatPeriod,
  );
  late final TabController _tabs = TabController(length: 3, vsync: this)..addListener(() => setState(() {}));
  List<Equipamento> _switches = [];
  String? _erroSwitches;
  Timer? _timer;
  int _ciclo = 0; // muda a cada recarga agendada: a contagem do topo recomeça
  StatusData? _data;
  String? _error;
  bool _loading = false;
  late bool _bip = _engine.savedBip;
  late bool _queda = _engine.savedQueda;
  bool get _soundOn => _bip || _queda;
  double _lastBeat = 0;
  int? _sortCol;
  bool _asc = true;

  Timer?
  _beepTimer; // só com movimento reduzido: sem animação, o bip segue num timer
  bool _reduced = false;
  String? _foco; // detalhe de uma MK aberto: o som segue só ela
  Timer? _focoTimer; // painel coberto não anima: o bip da MK focada vai num timer

  @override
  void initState() {
    super.initState();
    _beat.addListener(_onBeat);
    _tabs.index = painelAba.value;
    painelAba.addListener(_irParaAba);
    _agendar(inicial: true);
    final id = widget.abrir;
    if (id != null) WidgetsBinding.instance.addPostFrameCallback((_) => _abrir(id));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    _beepTimer?.cancel();
    _beepTimer = null;
    if (_reduced) {
      _beat.stop();
      _beepTimer = Timer.periodic(beatPeriod, (_) {
        if (_foco == null && _bip && _sound == MonitorSound.beep) _engine.beep();
      });
    } else if (!_beat.isAnimating) {
      _beat.repeat();
    }
  }

  @override
  void dispose() {
    _beepTimer?.cancel();
    _focoTimer?.cancel();
    _timer?.cancel();
    _beat.dispose();
    painelAba.removeListener(_irParaAba);
    _tabs.dispose();
    _engine.stop();
    super.dispose();
  }

  void _irParaAba() => _tabs.index = painelAba.value; // barra lateral de outra tela

  MonitorSound get _sound =>
      _data == null ? MonitorSound.silent : soundFor(_data!, foco: _foco);

  // O traçado reinicia a cada volta: o bip sai junto com o pico do batimento.
  void _onBeat() {
    if (_beat.value < _lastBeat && _foco == null && _bip && _sound == MonitorSound.beep) {
      _engine.beep();
    }
    _lastBeat = _beat.value;
  }

  void _applySound() {
    if (_queda && _sound == MonitorSound.flatline) {
      _engine.startFlatline();
    } else {
      _engine.stop();
    }
  }

  /// Recarrega agora e reinicia o relógio da recarga automática (o topo mostra quanto falta).
  void _agendar({bool inicial = false}) {
    _timer?.cancel();
    _load();
    if (inicial) {
      _ciclo++; // dentro do initState não pode setState
    } else if (mounted) {
      setState(() => _ciclo++);
    }
    _timer = Timer.periodic(_refresh, (_) {
      _load();
      if (mounted) setState(() => _ciclo++);
    });
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final d = await widget.api.status();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
      _applySound();
      try {
        final s = await widget.api.equipamentos(tipo: 'switch');
        if (!mounted) return;
        setState(() {
          _switches = s;
          _erroSwitches = null;
        });
      } catch (e) { // a aba Switch não derruba o painel das MKs
        if (!mounted || sessionExpired(context, e)) return;
        setState(() => _erroSwitches = 'Não foi possível carregar os switches.');
      }
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      setState(() => _error = errorText(e));
    } finally {
      _loading = false;
    }
  }

  Future<void> _abrir(String id) async {
    _foco = id;
    _applySound();
    _focoTimer = Timer.periodic(beatPeriod, (_) {
      if (_bip && _sound == MonitorSound.beep) _engine.beep();
    });
    await Navigator.of(context).pushNamed('/mk/$id');
    _focoTimer?.cancel();
    _focoTimer = null;
    _foco = null;
    if (!mounted) return;
    _applySound();
    _load();
  }

  void _toggleSound(String tipo) {
    setState(() {
      if (tipo == 'bip') {
        _engine.savedBip = _bip = !_bip;
      } else {
        _engine.savedQueda = _queda = !_queda;
      }
    });
    if (_soundOn) {
      _engine.unlock(); // dentro do clique: libera o áudio no navegador
    }
    _applySound();
  }

  // O navegador só libera áudio num clique: o primeiro toque em qualquer lugar (inclusive no
  // botão do menu de som, antes de escolher a opção) destrava, mesmo com o som todo desligado.
  void _onPointerDown() {
    if (!_engine.isSuspended) return;
    _engine.unlock();
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _logout() async {
    try {
      await widget.api.logout();
    } catch (_) {}
    usuarioAtual.value = null;
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    }
  }

  List<MkRow> _sorted(List<MkRow> rows) {
    final c = _sortCol;
    if (c == null) return rows;
    final col = _cols[c];
    // Estável: empate mantém a ordem do servidor.
    final idx = [for (var i = 0; i < rows.length; i++) i];
    idx.sort((i, j) {
      final a = rows[i], b = rows[j];
      final r = col.num != null
          ? col.num!(a).compareTo(col.num!(b))
          : col.text!(a).compareTo(col.text!(b));
      return r != 0 ? (_asc ? r : -r) : i.compareTo(j);
    });
    return [for (final i in idx) rows[i]];
  }

  void _sortBy(int i) => setState(() {
    if (_sortCol == i) {
      _asc = !_asc;
    } else {
      _sortCol = i;
      _asc = true;
    }
  });

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final d = _data;
    final aba = _tabs.index;
    return Listener(
      onPointerDown: (_) => _onPointerDown(),
      child: AppShell(
        ativo: const ['mk', 'switch', 'firewall'][aba],
        titulo: const ['MKs', 'Switches', 'Firewalls'][aba],
        subtitulo: aba == 0 && d != null ? '${d.mks.length} condomínios monitorados' : null,
        acoes: [
          if (aba == 0)
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pushNamed('/mk/novo').then((_) => _load()),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Nova MK'),
            ),
        ],
        contadores: {
          'mk': d == null ? 0 : d.fora + d.comAlerta,
          'switch': _switches.where(equipamentoComProblema).length,
        },
        aoNavegar: (c) => switch (c) {
          'mk' => _tabs.index = 0,
          'switch' => _tabs.index = 1,
          'firewall' => _tabs.index = 2,
          'eventos' => Navigator.of(context).pushNamed('/eventos'),
          'faixas' => Navigator.of(context).pushNamed('/faixas'),
          _ => Navigator.of(context).pushNamed('/preparar-mk'),
        },
        topo: [
          ContagemAtualizacao(intervalo: _refresh, ciclo: _ciclo, aoAtualizar: _agendar),
          if (_soundOn && _engine.isSuspended)
            Padding(
              padding: EdgeInsets.only(right: t.space2),
              child: Text('Clique para ativar o som', style: TradeType.label.copyWith(color: t.warning)),
            ),
        ],
        rodape: [
          PopupMenuButton<String>(
            tooltip: 'Som',
            position: PopupMenuPosition.over,
            icon: Icon(_soundOn ? Icons.volume_up_outlined : Icons.volume_off_outlined, size: 20, color: t.fgSecondary),
            onSelected: _toggleSound,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'bip', checked: _bip, child: const Text('Som de batimento')),
              CheckedPopupMenuItem(value: 'queda', checked: _queda, child: const Text('Som de perda')),
            ],
          ),
        ],
        fim: [IconButton(tooltip: 'Sair', icon: const Icon(Icons.logout, size: 20), onPressed: _logout)],
        body: IndexedStack(
          index: aba,
          children: [
            _mkBody(t, d),
            d == null
                ? const SizedBox()
                : SwitchesTab(api: widget.api, equipamentos: _switches, erro: _erroSwitches, mks: d.mks, onChanged: _load),
            Center(
              child: Text(
                'Nenhum firewall ainda. O suporte a firewall vem na próxima etapa.',
                style: TradeType.bodyLg.copyWith(color: t.fgSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mkBody(TradeTokens t, StatusData? d) {
    return d == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Text(
                        _error!,
                        style: TradeType.bodyMd.copyWith(color: t.negative),
                      ),
              )
            : ListView(
                padding: margemPagina(context),
                children: [
                  if (!d.dadosOk)
                    Aviso('Monitor parado — dados desatualizados', cor: t.negative),
                  if (!d.sedeOk)
                    Aviso('Sem conexão da sede — dados congelados', cor: t.warning),
                  if (d.filaPendente > 0)
                    Aviso(
                      d.filaPendente == 1
                          ? '1 evento aguardando envio'
                          : '${d.filaPendente} eventos aguardando envio',
                      cor: t.warning,
                    ),
                  if (_error != null)
                    Aviso('Falha ao atualizar: $_error', cor: t.negative),
                  Wrap(
                    spacing: t.space4,
                    runSpacing: t.space4,
                    children: [
                      _Summary(
                        const Key('resumo-no_ar'),
                        'No ar',
                        d.noAr,
                        t.positive,
                      ),
                      _Summary(
                        const Key('resumo-alerta'),
                        'Com alerta',
                        d.comAlerta,
                        t.warning,
                      ),
                      _Summary(
                        const Key('resumo-fora'),
                        'Fora',
                        d.fora,
                        t.negative,
                      ),
                    ],
                  ),
                  SizedBox(height: t.space6),
                  _table(context, t, _sorted(d.mks)),
                ],
              );
  }

  Widget _table(BuildContext context, TradeTokens t, List<MkRow> rows) {
    final head = TradeType.label.copyWith(color: t.fgSecondary);
    // cabeçalho em surface-200 (13/400), linhas com borda sutil e hover surface-300
    return LayoutBuilder(
      builder: (_, box) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: box.maxWidth < 920 ? 920 : box.maxWidth,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: t.bgSurface,
              borderRadius: BorderRadius.circular(t.radiusLg),
              border: Border.all(color: t.borderSubtle),
            ),
            child: Column(
              children: [
                Container(
                  color: t.bgSubtle,
                  padding: EdgeInsets.symmetric(horizontal: t.space3),
                  child: Row(
                  children: [
                    for (var i = 0; i < _cols.length; i++)
                      Expanded(
                        flex: _cols[i].flex,
                        child: Semantics(
                          button: true,
                          excludeSemantics: true,
                          label:
                              'Ordenar por ${_cols[i].label}${_sortCol == i ? (_asc ? ', crescente' : ', decrescente') : ''}',
                          onTap: () => _sortBy(i),
                          child: InkWell(
                            onTap: () => _sortBy(i),
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: t.space2),
                              child: Row(
                                children: [
                                  Text(_cols[i].label, style: head),
                                  if (_sortCol == i)
                                    Icon(
                                      _asc
                                          ? Icons.arrow_upward
                                          : Icons.arrow_downward,
                                      size: 16,
                                      color: t.fgSecondary,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    SizedBox(width: 112, child: Text('Batimento', style: head)),
                  ],
                ),
                ),
                Divider(color: t.borderSubtle, height: 1),
                for (final m in rows) _row(context, t, m),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, TradeTokens t, MkRow m) {
    final alert = m.alertas.isNotEmpty;
    final nums = dataStyle(context, TradeType.dataSm);
    return InkWell(
      key: ValueKey('row-${m.id}'),
      onTap: () => _abrir(m.id),
      hoverColor: t.bgHover,
      child: Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.borderSubtle))),
        padding: EdgeInsets.symmetric(vertical: t.space2, horizontal: t.space3),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.nome,
                    style: TradeType.heading4.copyWith(color: t.fgPrimary),
                  ),
                  if (alert)
                    Text(
                      m.alertas.join(' · '),
                      style: TradeType.bodyMd.copyWith(color: t.fgSecondary),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Align(
                alignment: Alignment.centerLeft,
                child: StatusPill(
                  status: m.status,
                  alert: alert,
                  desde: m.desde,
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Text(
                m.cpu == null ? '—' : '${m.cpu!.round()}%',
                style: nums,
              ),
            ),
            Expanded(
              flex: 1,
              child: Text(
                m.mem == null ? '—' : '${m.mem!.round()}%',
                style: nums,
              ),
            ),
            Expanded(flex: 2, child: Text(m.uptime ?? '—', style: nums)),
            Expanded(
              flex: 2,
              child: Text(
                m.ifacesTotal == 0 ? '—' : '${m.ifacesOk}/${m.ifacesTotal}',
                style: nums,
              ),
            ),
            SizedBox(
              width: 112,
              child: HeartbeatLine(
                status: m.status,
                alert: alert,
                beat: _beat,
                height: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary(Key key, this.label, this.value, this.color) : super(key: key);
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 220,
        child: Indicador(rotulo: label, valor: '$value', dica: value == 1 ? '1 MK' : '$value MKs', corDica: color),
      );
}

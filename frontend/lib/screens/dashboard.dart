import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../audio/monitor_sound.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/heartbeat.dart';

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
  const DashboardScreen({super.key, required this.api, this.sound});
  final ApiClient api;
  final SoundEngine? sound;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late final SoundEngine _engine = widget.sound ?? SoundEngine();
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: beatPeriod,
  );
  Timer? _timer;
  StatusData? _data;
  String? _error;
  bool _loading = false;
  late bool _soundOn = _engine.savedOn;
  double _lastBeat = 0;
  int? _sortCol;
  bool _asc = true;

  Timer?
  _beepTimer; // só com movimento reduzido: sem animação, o bip segue num timer
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _beat.addListener(_onBeat);
    _load();
    _timer = Timer.periodic(_refresh, (_) => _load());
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
        if (_soundOn && _sound == MonitorSound.beep) _engine.beep();
      });
    } else if (!_beat.isAnimating) {
      _beat.repeat();
    }
  }

  @override
  void dispose() {
    _beepTimer?.cancel();
    _timer?.cancel();
    _beat.dispose();
    _engine.stop();
    super.dispose();
  }

  MonitorSound get _sound =>
      _data == null ? MonitorSound.silent : soundFor(_data!);

  // O traçado reinicia a cada volta: o bip sai junto com o pico do batimento.
  void _onBeat() {
    if (_beat.value < _lastBeat && _soundOn && _sound == MonitorSound.beep) {
      _engine.beep();
    }
    _lastBeat = _beat.value;
  }

  void _applySound() {
    if (_soundOn && _sound == MonitorSound.flatline) {
      _engine.startFlatline();
    } else {
      _engine.stop();
    }
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
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      setState(() => _error = errorText(e));
    } finally {
      _loading = false;
    }
  }

  void _toggleSound() {
    setState(() => _soundOn = !_soundOn);
    _engine.savedOn = _soundOn;
    if (_soundOn) {
      _engine.unlock(); // dentro do clique: libera o áudio no navegador
    }
    _applySound();
  }

  // A preferência salva liga o som sem clique; o primeiro toque em qualquer lugar destrava.
  void _onPointerDown() {
    if (!_soundOn || !_engine.isSuspended) return;
    _engine.unlock();
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _logout() async {
    try {
      await widget.api.logout();
    } catch (_) {}
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
    return Listener(
      onPointerDown: (_) => _onPointerDown(),
      child: Scaffold(
        appBar: AppBar(
        automaticallyImplyLeading: false, // raiz da navegação logada: sem seta de voltar
          backgroundColor: t.bgPage,
          title: Text(
            'NodeBeat',
            style: TradeType.heading3.copyWith(color: t.fgPrimary),
          ),
          actions: [
            if (_soundOn && _engine.isSuspended)
              Text(
                'Clique para ativar o som',
                style: TradeType.label.copyWith(color: t.warning),
              ),
            IconButton(
              tooltip: _soundOn ? 'Som ligado' : 'Som desligado',
              icon: Icon(
                _soundOn ? Icons.volume_up_outlined : Icons.volume_off_outlined,
                size: 20,
              ),
              onPressed: _toggleSound,
            ),
            const ThemeToggle(),
            IconButton(
              tooltip: 'Sair',
              icon: const Icon(Icons.logout, size: 20),
              onPressed: _logout,
            ),
            SizedBox(width: t.space2),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: t.actionPrimary,
          foregroundColor: t.actionPrimaryFg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radiusPill),
          ),
          onPressed: () =>
              Navigator.of(context).pushNamed('/mk/novo').then((_) => _load()),
          icon: const Icon(Icons.add, size: 20),
          label: const Text('Nova MK'),
        ),
        body: d == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Text(
                        _error!,
                        style: TradeType.bodyMd.copyWith(color: t.negative),
                      ),
              )
            : ListView(
                padding: EdgeInsets.all(t.space6),
                children: [
                  if (!d.sedeOk)
                    _Banner(
                      'Sem conexão da sede — dados congelados',
                      t.warning,
                    ),
                  if (d.filaPendente > 0)
                    _Banner(
                      d.filaPendente == 1
                          ? '1 evento aguardando envio'
                          : '${d.filaPendente} eventos aguardando envio',
                      t.warning,
                    ),
                  if (_error != null)
                    _Banner('Falha ao atualizar: $_error', t.negative),
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
                  SizedBox(height: t.space12),
                  _table(context, t, _sorted(d.mks)),
                ],
              ),
      ),
    );
  }

  Widget _table(BuildContext context, TradeTokens t, List<MkRow> rows) {
    final head = TradeType.label.copyWith(color: t.fgSecondary);
    return LayoutBuilder(
      builder: (_, box) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: box.maxWidth < 920 ? 920 : box.maxWidth,
          child: TradeCard(
            child: Column(
              children: [
                Row(
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
      onTap: () =>
          Navigator.of(context).pushNamed('/mk/${m.id}').then((_) => _load()),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: t.space3),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.nome,
                    style: TradeType.bodyMd.copyWith(
                      color: t.fgPrimary,
                      fontWeight: FontWeight.w600,
                    ),
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

class _Banner extends StatelessWidget {
  const _Banner(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: t.space4),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: t.space4,
            vertical: t.space3,
          ),
          decoration: BoxDecoration(
            color: t.bgElevated,
            borderRadius: BorderRadius.circular(t.radiusMd),
            border: Border.all(color: color),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber_outlined, size: 20, color: color),
              SizedBox(width: t.space3),
              Expanded(
                child: Text(
                  text,
                  style: TradeType.bodyMd.copyWith(color: t.fgPrimary),
                ),
              ),
            ],
          ),
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
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return SizedBox(
      width: 220,
      child: TradeCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TradeType.label.copyWith(color: t.fgSecondary)),
            SizedBox(height: t.space2),
            Text(
              '$value',
              style: dataStyle(
                context,
                TradeType.dataLg,
              ).copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

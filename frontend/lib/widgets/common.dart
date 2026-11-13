import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';

/// Tempo desde [iso] em "<1 min", "N min", "N h" ou "N d".
String relativo(String? iso, {DateTime? now}) {
  final t = iso == null ? null : DateTime.tryParse(iso);
  if (t == null) return '';
  final m = (now ?? DateTime.now()).difference(t).inMinutes;
  if (m < 1) return '<1 min';
  if (m < 60) return '$m min';
  if (m < 1440) return '${m ~/ 60} h';
  return '${m ~/ 1440} d';
}

String two(int n) => n.toString().padLeft(2, '0');

/// ISO 8601 -> "dd/MM/yyyy HH:mm" no horário local.
String formatDateTime(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// 45 -> "45 s", 3900 -> "1 h 5 min".
String formatDuration(int s) {
  if (s < 60) return '$s s';
  final m = s ~/ 60;
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  if (h < 24) return m % 60 == 0 ? '$h h' : '$h h ${m % 60} min';
  return h % 24 == 0 ? '${h ~/ 24} d' : '${h ~/ 24} d ${h % 24} h';
}

String statusLabel(String status, bool alert) => switch (status) {
      'no_ar' => alert ? 'Alerta' : 'No ar',
      'offline' => 'Offline',
      'vpn_caiu' => 'VPN caiu',
      'erro_acesso' => 'Erro de acesso',
      _ => 'Aguardando',
    };

Color statusColor(TradeTokens t, String status, bool alert) => switch (status) {
      'no_ar' => alert ? t.warning : t.positive,
      'aguardando' => t.fgSecondary,
      _ => t.negative,
    };

/// Pílula "VPN caiu · 6 min".
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, required this.alert, this.desde});
  final String status;
  final bool alert;
  final String? desde;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final c = statusColor(t, status, alert);
    final rel = relativo(desde);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: t.space3, vertical: t.space1),
      decoration: BoxDecoration(
        color: t.bgElevated,
        borderRadius: BorderRadius.circular(t.radiusPill),
        border: Border.all(color: c),
      ),
      child: Text(rel.isEmpty ? statusLabel(status, alert) : '${statusLabel(status, alert)} · $rel',
          style: TradeType.label.copyWith(color: c)),
    );
  }
}

/// Sessão expirada (401) volta ao login. Devolve true se tratou o erro.
bool sessionExpired(BuildContext context, Object e) {
  if (e is ApiError && e.status == 401) {
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    return true;
  }
  return false;
}

/// Seta de voltar para telas que podem abrir por deep link: sem rota por baixo, vai ao painel.
/// Com rota por baixo devolve null e o AppBar põe a seta padrão.
Widget? backFallback(BuildContext context) => Navigator.of(context).canPop()
    ? null
    : IconButton(
        tooltip: 'Voltar',
        icon: const Icon(Icons.arrow_back, size: 20),
        onPressed: () => Navigator.of(context).pushReplacementNamed('/painel'),
      );

String errorText(Object e) => e is ApiError ? e.message : 'Não foi possível conectar ao servidor';

/// Cartão padrão: radius-xl, padding space-6.
class TradeCard extends StatelessWidget {
  const TradeCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      padding: EdgeInsets.all(t.space6),
      decoration: BoxDecoration(
        color: t.bgSurface,
        borderRadius: BorderRadius.circular(t.radiusXl),
        border: Border.all(color: t.borderSubtle),
      ),
      child: child,
    );
  }
}

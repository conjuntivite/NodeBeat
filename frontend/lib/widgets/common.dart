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
      'reiniciando' => 'Reiniciando',
      _ => 'Aguardando',
    };

Color statusColor(TradeTokens t, String status, bool alert) => switch (status) {
      'no_ar' => alert ? t.warning : t.positive,
      'aguardando' => t.fgSecondary,
      'reiniciando' => t.info,
      _ => t.negative,
    };

/// Fundo do selo para a cor de status (`*-bg` do tema); cor sem par cai no neutro.
Color statusBg(TradeTokens t, Color c) => c == t.positive
    ? t.positiveBg
    : c == t.negative
        ? t.negativeBg
        : c == t.warning
            ? t.warningBg
            : c == t.info
                ? t.infoBg
                : c == t.brandText
                    ? t.brandTint
                    : t.bgHover;

/// Selo de status com ponto: "VPN caiu · 6 min".
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, required this.alert, this.desde});
  final String status;
  final bool alert;
  final String? desde;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final rel = relativo(desde);
    return Selo(rel.isEmpty ? statusLabel(status, alert) : '${statusLabel(status, alert)} · $rel',
        statusColor(t, status, alert), ponto: true);
  }
}

/// Badge do design system: texto 12/500 na cor de status sobre o seu fundo, raio sm.
class Selo extends StatelessWidget {
  const Selo(this.texto, this.cor, {super.key, this.ponto = false});
  final String texto;
  final Color cor;
  final bool ponto;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final fg = cor == t.fgSecondary ? t.fgPrimary : cor; // neutro: tinta sobre surface-300
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(color: statusBg(t, cor), borderRadius: BorderRadius.circular(t.radiusSm)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (ponto) ...[
          Container(width: 8, height: 8, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 6),
        ],
        Flexible(
            child: Text(texto,
                overflow: TextOverflow.ellipsis,
                style: TradeType.bodySm.copyWith(color: fg, fontWeight: FontWeight.w500))),
      ]),
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

/// Cartão do design system: surface-100, borda sutil, radius-lg, padding space-4, sombra leve.
/// Com [titulo], cabeçalho h3 (e [acoes] à direita) antes do corpo.
class TradeCard extends StatelessWidget {
  const TradeCard({super.key, required this.child, this.titulo, this.acoes = const []});
  final Widget child;
  final String? titulo;
  final List<Widget> acoes;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.all(t.space4),
      decoration: BoxDecoration(
        color: t.bgSurface,
        borderRadius: BorderRadius.circular(t.radiusLg),
        border: Border.all(color: t.borderSubtle),
        boxShadow: [BoxShadow(color: dark ? const Color(0x66000000) : t.fgPrimary.withValues(alpha: .10), blurRadius: 2, offset: const Offset(0, 1))],
      ),
      child: titulo == null
          ? child
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: Text(titulo!, style: TradeType.heading3.copyWith(color: t.fgPrimary))),
                ...acoes,
              ]),
              SizedBox(height: t.space4),
              child,
            ]),
    );
  }
}

/// Carrega um recurso do inventário; erros (exceto 401) viram texto no cartão.
mixin Carrega<W extends StatefulWidget, T> on State<W> {
  T? dados;
  String? erro;
  Future<T> buscar();
  int _pedido = 0; // resposta de um pedido antigo (mais lento) nunca sobrescreve a do mais novo
  bool get carregando => _carregando;
  bool _carregando = false;

  Future<void> carregar() async {
    final n = ++_pedido;
    _carregando = true;
    try {
      final d = await buscar();
      if (mounted && n == _pedido) {
        setState(() {
          dados = d;
          erro = null;
        });
      }
    } catch (e) {
      if (!mounted || n != _pedido || sessionExpired(context, e)) return;
      setState(() => erro = errorText(e));
    } finally {
      if (n == _pedido) _carregando = false;
    }
  }

  @override
  void initState() {
    super.initState();
    carregar();
  }
}

/// Sobretítulo em caixa alta (mono). A caixa alta vem do texto, não de estilo.
Widget eyebrow(String texto, {required Color cor}) =>
    Text(texto.toUpperCase(), style: TradeType.eyebrow.copyWith(color: cor));

/// Pílula: o mesmo [Selo] (cor de status sobre o seu fundo), mantida pelo nome antigo.
class Pilula extends StatelessWidget {
  const Pilula(this.texto, {super.key, required this.cor, this.ponto = false});
  final String texto;
  final Color cor;
  final bool ponto;

  @override
  Widget build(BuildContext context) => Selo(texto, cor, ponto: ponto);
}

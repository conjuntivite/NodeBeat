import 'package:material_ui/material_ui.dart';

import '../theme/theme.dart';
import '../theme/tokens.g.dart';

/// Aba do painel que a barra lateral pediu (0 MK, 1 Switch, 2 Firewall); o painel escuta.
final painelAba = ValueNotifier<int>(0);

typedef ItemNav = ({String chave, String rotulo, IconData icone});

const itensNav = <ItemNav>[
  (chave: 'mk', rotulo: 'MK', icone: Icons.router_outlined),
  (chave: 'switch', rotulo: 'Switch', icone: Icons.lan_outlined),
  (chave: 'firewall', rotulo: 'Firewall', icone: Icons.shield_outlined),
  (chave: 'eventos', rotulo: 'Eventos', icone: Icons.insights_outlined),
  (chave: 'faixas', rotulo: 'Faixas de IP', icone: Icons.account_tree_outlined),
  (chave: 'preparar', rotulo: 'Preparar MK', icone: Icons.terminal),
];

const _abas = {'mk': 0, 'switch': 1, 'firewall': 2};
const _rotas = {'eventos': '/eventos', 'faixas': '/faixas', 'preparar': '/preparar-mk'};

/// Navega pela barra lateral. O painel fica sempre na base da pilha (ele toca o som);
/// aberto por link direto, sem painel por baixo, a tela pedida substitui a atual.
void irPara(BuildContext context, String chave) {
  final nav = Navigator.of(context);
  var temPainel = false;
  nav.popUntil((r) {
    if (r.settings.name == '/painel') return temPainel = true;
    return r.isFirst;
  });
  final aba = _abas[chave];
  if (aba != null) {
    painelAba.value = aba;
    if (!temPainel) nav.pushReplacementNamed('/painel');
  } else if (temPainel) {
    nav.pushNamed(_rotas[chave]!);
  } else {
    nav.pushReplacementNamed(_rotas[chave]!);
  }
}

/// Volta para a tela anterior; aberta por link direto (nada por baixo), vai ao painel.
void voltar(BuildContext context) {
  final nav = Navigator.of(context);
  nav.canPop() ? nav.pop() : nav.pushReplacementNamed('/painel');
}

/// Casca das telas logadas: barra lateral de ícones, barra do topo e cabeçalho de página.
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.ativo,
    required this.titulo,
    required this.body,
    this.subtitulo,
    this.migalhas,
    this.acoes = const [],
    this.topo = const [],
    this.rodape = const [],
    this.contadores = const {},
    this.aoNavegar,
  });

  final String ativo; // chave de [itensNav]
  final String titulo;
  final String? subtitulo;
  final Widget? migalhas; // breadcrumb acima do título
  final List<Widget> acoes; // botões à direita do título
  final List<Widget> topo; // à direita da barra do topo (antes do tema)
  final List<Widget> rodape; // fim da barra lateral (antes de tema/sair)
  final Map<String, int> contadores; // problemas por item da barra
  final void Function(String chave)? aoNavegar;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final estreita = MediaQuery.sizeOf(context).width < 600; // celular: navegação vira menu
    final margem = margemLateral(context);
    void navegar(BuildContext c, String chave) => (aoNavegar ?? (k) => irPara(context, k))(chave);
    Widget itens(BuildContext c, {required bool comRotulo}) => Column(
      crossAxisAlignment: comRotulo ? CrossAxisAlignment.stretch : CrossAxisAlignment.center,
      children: [
        for (final i in itensNav) ...[
          _ItemLateral(
            item: i,
            ativo: i.chave == ativo,
            contador: contadores[i.chave] ?? 0,
            comRotulo: comRotulo,
            onTap: () {
              if (comRotulo) Navigator.of(c).pop(); // fecha o menu antes de navegar
              navegar(c, i.chave);
            },
          ),
          SizedBox(height: t.space2),
        ],
        const Spacer(),
        Row(
          mainAxisAlignment: comRotulo ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [if (comRotulo) ...rodape, if (comRotulo) const ThemeToggle()],
        ),
        if (!comRotulo) ...[...rodape, const ThemeToggle()],
      ],
    );
    final lateral = Container(
      padding: EdgeInsets.symmetric(vertical: t.space3, horizontal: t.space2),
      decoration: BoxDecoration(
        color: t.bgSubtle,
        border: Border(right: BorderSide(color: t.borderSubtle)),
      ),
      child: Semantics(
        container: true,
        label: 'Navegação principal',
        child: Builder(builder: (c) => itens(c, comRotulo: estreita)),
      ),
    );
    return Scaffold(
      drawer: estreita
          ? Drawer(
              width: 248,
              backgroundColor: t.bgSubtle,
              shape: const RoundedRectangleBorder(),
              child: SafeArea(child: lateral),
            )
          : null,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!estreita) SizedBox(width: 56, child: lateral),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 56,
                  padding: EdgeInsets.symmetric(horizontal: estreita ? t.space2 : t.space6),
                  decoration: BoxDecoration(
                    color: t.bgSurface,
                    border: Border(bottom: BorderSide(color: t.borderSubtle)),
                  ),
                  child: Row(
                    children: [
                      if (estreita)
                        Builder(
                          builder: (c) => IconButton(
                            tooltip: 'Menu',
                            icon: const Icon(Icons.menu, size: 20),
                            onPressed: () => Scaffold.of(c).openDrawer(),
                          ),
                        ),
                      Image.asset(
                        dark ? 'assets/brand/nodebeat-icon-dark.png' : 'assets/brand/nodebeat-icon-light.png',
                        width: 28,
                        height: 28,
                        excludeFromSemantics: true, // o nome vem logo ao lado
                      ),
                      SizedBox(width: t.space3),
                      Flexible(
                        child: Text(
                          'NodeBeat',
                          overflow: TextOverflow.ellipsis,
                          style: TradeType.displayXl.copyWith(
                            fontSize: 22,
                            height: 28 / 22,
                            letterSpacing: -.3,
                            color: t.fgPrimary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      ...topo,
                    ],
                  ),
                ),
                Expanded(
                  child: _Rolagem(
                    margem: margem,
                    cabecalho: PageHeader(titulo: titulo, subtitulo: subtitulo, migalhas: migalhas, acoes: acoes),
                    body: body,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Cabeçalho fixo acima do corpo (o corpo rola sozinho, como as telas já fazem).
class _Rolagem extends StatelessWidget {
  const _Rolagem({required this.margem, required this.cabecalho, required this.body});
  final double margem;
  final Widget cabecalho, body;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(padding: EdgeInsets.fromLTRB(margem, margem, margem, 0), child: cabecalho),
      Expanded(child: body),
    ],
  );
}

/// Margem da página dentro da [AppShell]: 32 px; 16 px no celular (< 600 px).
double margemLateral(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 600 ? tokensOf(context).space4 : tokensOf(context).space8;

/// Padding do corpo rolável das telas (sem topo: o cabeçalho já tem).
EdgeInsets margemPagina(BuildContext context) {
  final m = margemLateral(context);
  return EdgeInsets.fromLTRB(m, 0, m, m);
}

class _ItemLateral extends StatelessWidget {
  const _ItemLateral({
    required this.item,
    required this.ativo,
    required this.contador,
    required this.onTap,
    this.comRotulo = false,
  });
  final ItemNav item;
  final bool comRotulo;
  final bool ativo;
  final int contador;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Tooltip(
      message: item.rotulo,
      child: Semantics(
        button: true,
        selected: ativo,
        label: contador > 0 ? '${item.rotulo}, $contador com problema' : item.rotulo,
        excludeSemantics: true,
        child: Material(
          color: ativo ? t.actionPrimary : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radiusMd)),
          child: InkWell(
            key: Key('nav-${item.chave}'),
            borderRadius: BorderRadius.circular(t.radiusMd),
            hoverColor: ativo ? t.brandHover : t.bgHover,
            onTap: onTap,
            child: SizedBox(
              width: comRotulo ? null : 40,
              height: 40,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: comRotulo ? Alignment.centerLeft : Alignment.center,
                children: [
                  if (comRotulo)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: t.space3),
                      child: Row(
                        children: [
                          Icon(item.icone, size: 20, color: ativo ? t.actionPrimaryFg : t.fgSecondary),
                          SizedBox(width: t.space3),
                          Text(
                            item.rotulo,
                            style: TradeType.button.copyWith(color: ativo ? t.actionPrimaryFg : t.fgPrimary),
                          ),
                        ],
                      ),
                    )
                  else
                    Icon(item.icone, size: 20, color: ativo ? t.actionPrimaryFg : t.fgSecondary),
                  if (contador > 0)
                    Positioned(
                      top: comRotulo ? 11 : -4,
                      right: comRotulo ? t.space3 : -4,
                      child: Container(
                        key: Key('contador-${item.chave}'),
                        constraints: const BoxConstraints(minWidth: 18),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: t.negative, // negative + fgInverse passa 4,5:1 nos dois temas
                          borderRadius: BorderRadius.circular(t.radiusPill),
                          border: Border.all(color: t.bgSubtle, width: 2),
                        ),
                        child: Text(
                          '$contador',
                          textAlign: TextAlign.center,
                          style: TradeType.bodySm.copyWith(
                            color: t.fgInverse,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cabeçalho de página: migalhas, título h1 (36/300), subtítulo e ações à direita.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.titulo, this.subtitulo, this.migalhas, this.acoes = const []});
  final String titulo;
  final String? subtitulo;
  final Widget? migalhas;
  final List<Widget> acoes;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: t.space6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (migalhas != null) ...[migalhas!, SizedBox(height: t.space2)],
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: t.space4,
            runSpacing: t.space2,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    child: Text(titulo, style: TradeType.heading1.copyWith(color: t.fgPrimary)),
                  ),
                  if (subtitulo != null) Text(subtitulo!, style: TradeType.bodyLg.copyWith(color: t.fgSecondary)),
                ],
              ),
              if (acoes.isNotEmpty) Wrap(spacing: t.space2, runSpacing: t.space2, children: acoes),
            ],
          ),
        ],
      ),
    );
  }
}

/// Migalhas "Painel / UNIFI PRO": a primeira volta para a tela anterior.
class Migalhas extends StatelessWidget {
  const Migalhas({super.key, required this.anterior, required this.atual, required this.aoVoltar});
  final String anterior, atual;
  final VoidCallback aoVoltar;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final s = TradeType.label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Voltar',
          child: InkWell(
            onTap: aoVoltar,
            borderRadius: BorderRadius.circular(t.radiusSm),
            child: Text(anterior, style: s.copyWith(color: t.brandText)),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space2),
          child: Text('/', style: s.copyWith(color: t.borderStrong)),
        ),
        Flexible(
          child: Text(
            atual,
            overflow: TextOverflow.ellipsis,
            style: s.copyWith(color: t.fgPrimary),
          ),
        ),
      ],
    );
  }
}

/// Indicador (Stat): rótulo 13, valor 36/200, dica 12.
class Indicador extends StatelessWidget {
  const Indicador({super.key, required this.rotulo, required this.valor, this.dica, this.corDica});
  final String rotulo, valor;
  final String? dica;
  final Color? corDica;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 160),
      padding: EdgeInsets.all(t.space4),
      decoration: BoxDecoration(
        color: t.bgSurface,
        border: Border.all(color: t.borderSubtle),
        borderRadius: BorderRadius.circular(t.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(rotulo, style: TradeType.label.copyWith(color: t.fgSecondary)),
          SizedBox(height: t.space1),
          Text(valor, style: dataStyle(context, TradeType.dataXl)),
          if (dica != null) Text(dica!, style: TradeType.bodySm.copyWith(color: corDica ?? t.fgSecondary)),
        ],
      ),
    );
  }
}

/// Abas em pílula (Tabs do design system): fundo surface-200, ativa em pink.
class AbasPilula extends StatelessWidget {
  const AbasPilula({super.key, required this.itens, required this.valor, required this.aoMudar});
  final List<String> itens;
  final int valor;
  final ValueChanged<int> aoMudar;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return SingleChildScrollView(
      // em tela estreita as pílulas rolam em vez de estourar
      scrollDirection: Axis.horizontal,
      child: Container(
        padding: EdgeInsets.all(t.space1),
        decoration: BoxDecoration(
          color: t.bgSubtle,
          border: Border.all(color: t.borderSubtle),
          borderRadius: BorderRadius.circular(t.radiusPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < itens.length; i++)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : t.space1),
                child: Semantics(
                  button: true,
                  selected: i == valor,
                  child: Material(
                    color: i == valor ? t.actionPrimary : Colors.transparent,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      hoverColor: i == valor ? t.brandHover : t.bgHover,
                      onTap: () => aoMudar(i),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: t.space4, vertical: 6),
                        child: Text(
                          itens[i],
                          style: TradeType.button.copyWith(color: i == valor ? t.actionPrimaryFg : t.fgSecondary),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Alerta do design system: fundo da cor de status, borda na cor, título 500.
class Aviso extends StatelessWidget {
  const Aviso(this.texto, {super.key, required this.cor, this.icone = Icons.warning_amber_outlined});
  final String texto;
  final Color cor;
  final IconData icone;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final bg = cor == t.negative
        ? t.negativeBg
        : cor == t.warning
        ? t.warningBg
        : cor == t.positive
        ? t.positiveBg
        : t.infoBg;
    return Padding(
      padding: EdgeInsets.only(bottom: t.space4),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: t.space4, vertical: t.space3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(t.radiusMd),
            border: Border.all(color: cor),
          ),
          child: Row(
            children: [
              Icon(icone, size: 20, color: cor),
              SizedBox(width: t.space3),
              Expanded(
                child: Text(
                  texto,
                  style: TradeType.bodyMd.copyWith(color: cor, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

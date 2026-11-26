# Paleta na TV inteira — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A paleta escolhida pinta a tela inteira da TV (sem pink) e o botão claro/escuro sai da TV.

**Architecture:** `TradeTokens` ganha `copyWith` (gerado por `tool/gen_tokens.dart`); `tokensOf` passa a respeitar um `InheritedWidget` de sobrescrita (`TokensDaTela`) antes do brilho do tema; `tradeTheme` aceita tokens opcionais. A TV embrulha seu conteúdo em `Theme(data: tradeTheme(b, tk))` + `TokensDaTela(tk)`, com `tk` derivado da paleta (`tokensDaPaleta`).

**Spec:** `docs/superpowers/specs/2026-11-26-paletas-mapa-design.md` (seção "Revisão 2026-11-26").

## Global Constraints
- Valores novos (`escura`, `painel`, `bordaPainel`, `textoSec`) exatamente como na tabela da revisão.
- Fora da TV nada muda (popup e demais telas com os mesmos tokens de hoje). Não mexer em `lib/widgets/heartbeat.dart`. Sem dependência nova. pt-BR.

### Task 1: Paleta como tema da TV
**Files:** Modify `frontend/tool/gen_tokens.dart` (+ regenerar `lib/theme/tokens.g.dart`), `lib/theme/theme.dart`, `lib/ataques/paletas.dart`, `lib/screens/mapa_ataques_tv.dart`; Tests `test/paletas_test.dart`, `test/mapa_ataques_tv_test.dart`.

**Interfaces — Produces:**
- `TradeTokens.copyWith({...todas as cores})` gerado.
- `class TokensDaTela extends InheritedWidget { const TokensDaTela({required TradeTokens tokens, required Widget child}); }`; `tokensOf(c)` = `TokensDaTela` mais próximo, senão o atual.
- `ThemeData tradeTheme(Brightness b, [TradeTokens? tk])` (sem `tk` = igual a hoje).
- `PaletaMapa` ganha `escura` (bool), `painel`, `bordaPainel`, `textoSec`; `TradeTokens tokensDaPaleta(PaletaMapa p)`: base `TradeTokens.dark`/`.light` por `escura`; `bgPage`,`bgSubtle` = `fundo`; `bgSurface`,`bgElevated` = `painel`; `bgHover` = `texto` com alpha 0.08; `borderSubtle`,`borderStrong` = `bordaPainel`; `fgPrimary` = `texto`; `fgSecondary`,`fgMuted` = `textoSec`; `actionPrimary`,`actionAccent`,`focusRing`,`bgBrand`,`bgBrandDeep`,`brandHover`,`brandText`,`chart1` = `vias[0]`; `brandTint` = `vias[0]` alpha 0.15; `actionPrimaryFg`,`fgOnBrand` = `fundo`; o resto (status, raios, espaços) da base.

- [ ] Testes que falham: `tokensDaPaletaSemPink` (para as 8: nenhuma cor de `tokensDaPaleta` entre `#CE2274`, `#FF4FA3`, `#E868A5`, `#F8E9F0`, `#F1DCE6`, `#FCF5F8`, `#441B2F`, `#4F293B`, `#311422`, `#240E18` — comparar RGB das cores de fundo/borda/marca listadas acima); `tvPintaComAPaleta` (TV com paleta `oceano` → `Scaffold.backgroundColor == fundo` do oceano e o título 'Ataques às MKs' com cor `texto`); `tvSemBotaoDeTema` (TV não tem `ThemeToggle`; tem o tooltip "Paleta do mapa"); `tvIgnoraTemaGlobal` (com `themeMode` claro, TV na paleta `ardosia` usa brilho escuro no seu `Theme`); `foraDaTvTokensIguais` (`tokensOf` sem `TokensDaTela` == `TradeTokens.light` no tema claro). Remover/ajustar `tvGuardaTema` e o que depender do botão de tema na TV.
- [ ] Implementar: TV embrulha o `Scaffold` em `Theme(data: tradeTheme(p.escura ? dark : light, tk), child: TokensDaTela(tokens: tk, child: ...))`; cabeçalho com fundo `painel` e borda inferior `bordaPainel`; ícone da marca `-dark`/`-light` por `escura`; remover `ThemeToggle`, `temaTvSalvo`/`salvarTemaTv` e o listener de `themeMode` da TV (apagar as funções de `aba*.dart` se não tiverem outro uso). Lista ao vivo e coluna de tops já usam `tokensOf` → passam a pegar o painel.
- [ ] `flutter test` e `flutter analyze` verdes; commit `feat(front): paleta pinta a TV inteira, sem botao de tema`.

### Task 2: Revisão final, deploy e conferência no Chrome (dono já aprovou deploy e push)

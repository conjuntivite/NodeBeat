# Paletas do mapa — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mapa sem pink, com 8 paletas fixas escolhidas na TV e salvas no navegador.

**Architecture:** `lib/ataques/paletas.dart` define `PaletaMapa` e as 8 paletas. `MapaAtaques` recebe `PaletaMapa? paleta` (nulo → `cinza`/`ardosia` pelo brilho do tema) e usa a paleta em tudo que é desenhado sobre o mapa; `corVia` passa a receber a paleta. A TV guarda o id no localStorage e oferece o seletor no cabeçalho.

**Tech Stack:** Flutter web 3.50 (`material_ui`, `package:web`), sem dependência nova.

**Spec:** `docs/superpowers/specs/2026-11-26-paletas-mapa-design.md`

## Global Constraints
- Valores das 8 paletas exatamente como na tabela da spec; ids `ardosia, cinza, noite, oceano, grafite, papel, floresta, alto`; login aceito `#EF4444`.
- Nenhum pink na área do mapa (nem `actionPrimary`, `chart1`, `bgHover`, `borderSubtle`, `bgSubtle`).
- localStorage `nodebeat_tv_paleta`; padrão da TV `ardosia`; popup: `cinza` (claro) / `ardosia` (escuro).
- Fora do mapa, tokens via `tokensOf(context)`; textos pt-BR; botão só de ícone com tooltip/semântica "Paleta do mapa"; sem emoji; não mexer em `lib/widgets/heartbeat.dart`; sem dependência nova.

## Review Focus
1. Id salvo inválido/antigo → paleta padrão, sem exceção → `paletaDesconhecidaUsaPadrao` (Task 1).
2. Texto sobre o mapa (legenda, "Todas as MKs, ao vivo", rótulos de MK, "+N", "IP data by DB-IP") usa a cor de texto da paleta, não `fgSecondary` do tema (ilegível em paleta escura no tema claro) → `rotulosUsamCorDaPaleta` (Task 1).
3. Trocar paleta repinta o mapa já carregado (shouldRepaint compara cores/paleta) → `trocarPaletaRepinta` (Task 2).
4. Popup não mostra seletor e usa o padrão do tema → `popupSemSeletor` (Task 2).
5. Escolha sobrevive a reabrir a TV → `tvGuardaPaleta` (Task 2).

---

### Task 1: Paletas e mapa sem pink
**Files:** Create `frontend/lib/ataques/paletas.dart`, `frontend/test/paletas_test.dart`; Modify `frontend/lib/widgets/mapa_ataques.dart`, `frontend/lib/widgets/ataques_tv.dart`, testes existentes que chamem `corVia`/`ListaAoVivo`/`ColunaTops`.

**Interfaces — Produces:**
- `class PaletaMapa { const PaletaMapa({required String id, required String nome, required Color fundo, required Color terra, required Color borda, required Color texto, required List<Color> vias}); }` (`texto` = destino e rótulos; `vias.length == 6`); `const corAceito = Color(0xFFEF4444);`
- `const List<PaletaMapa> paletasMapa` (ordem da tabela); `PaletaMapa paletaPorId(String? id)` → `ardosia` se nulo/desconhecido; `PaletaMapa paletaPadrao(Brightness b)` → `cinza` (light) / `ardosia` (dark).
- `Color corVia(PaletaMapa p, String via)` (substitui a versão com `TradeTokens`; índice em `viasAtaque`, resto → `vias[5]`).
- `MapaAtaques({..., PaletaMapa? paleta})`; `ListaAoVivo({required recentes, required PaletaMapa paleta})`; `ColunaTops({required acesso, required PaletaMapa paleta})`.

- [ ] Testes que falham: `paletasCompletas` (8 paletas, ids da spec na ordem, 6 vias cada, nenhuma cor igual a `#CE2274`/`#FF4FA3`/`#E868A5`); `paletaDesconhecidaUsaPadrao` (`paletaPorId('xyz').id == 'ardosia'`, `paletaPorId(null).id == 'ardosia'`); `paletaPadraoPorTema`; `rotulosUsamCorDaPaleta` (MapaAtaques com `paleta: paletaPorId('papel')` em tema escuro → o Text 'SSH' da legenda tem cor com RGB de `texto` da paleta); `mapaUsaFundoDaPaleta` (há um widget de fundo da área do mapa com `paleta.fundo`).
- [ ] Implementar: área do mapa com `paleta.fundo`; `_Terra(terra, borda)`; `_Linhas` recebe a paleta (linha `corAceito` se sucesso senão `corVia`; ponto de destino e rótulos de MK em `paleta.texto`); legenda, eyebrow, "+N" e "IP data by DB-IP" com `paleta.texto` (secundário = mesma cor com alpha ≥ 0.75). Pílulas "ao vivo"/"sem dados" e as faixas de aviso ficam como estão. Lista e coluna usam `corVia(paleta, …)`; o selo "Acesso aceito" continua `negative`.
- [ ] `flutter test` e `flutter analyze` verdes; commit `feat(front): paletas do mapa sem pink`.

### Task 2: Seletor de paleta na TV
**Files:** Modify `frontend/lib/screens/mapa_ataques_tv.dart`, `frontend/lib/ataques/aba.dart`, `aba_stub.dart`, `aba_web.dart`; Test `frontend/test/mapa_ataques_tv_test.dart`, `frontend/test/mapa_ataques_test.dart`.

**Interfaces — Consumes:** Task 1 (`paletasMapa`, `paletaPorId`, `paletaPadrao`, `MapaAtaques(paleta:)`). **Produces:** `String? paletaTvSalva()`, `void salvarPaletaTv(String id)` em `aba.dart` (web: localStorage `nodebeat_tv_paleta`; stub: memória).

- [ ] Testes que falham: `tvGuardaPaleta` (abrir TV → `MapaAtaques.paleta.id == 'ardosia'`; tocar em "Paleta do mapa", escolher "Oceano" → `paletaTvSalva() == 'oceano'` e `MapaAtaques` recebe oceano; reabrir a TV → oceano); `trocarPaletaRepinta` (após escolher, o fundo da área do mapa tem a cor `fundo` da nova paleta); `popupSemSeletor` (`MapaAtaques(tv: false)` sem paleta em tema claro usa `cinza` e não há "Paleta do mapa").
- [ ] Implementar: estado da paleta na TV (lê `paletaTvSalva()` no `initState`); `IconButton` (`Icons.palette_outlined`, tooltip "Paleta do mapa") ao lado do `ThemeToggle`, abrindo `MenuAnchor` ou `PopupMenuButton` com as 8 opções: miniatura 40×24 (fundo + faixa da terra + 3 pontos das vias) + nome, a atual com check.
- [ ] `flutter test` e `flutter analyze` verdes; commit `feat(front): seletor de paleta do mapa na TV`.

### Task 3: Revisão final e deploy (com o dono)
- [ ] Revisão da branch; conferir no Chrome a TV com 2–3 paletas nos dois temas e o popup; merge, push e deploy do `web` só com o ok do dono.

# TV de ataques — layout FortiGuard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lista ao vivo embaixo do mapa, coluna de tops 24 h à direita com bandeiras, e tema claro/escuro escolhido na própria TV.

**Architecture:** Tudo no front Flutter. `MapaAtaques` (lib/widgets/mapa_ataques.dart) já tem o feed (5 s) e o painel 24 h (60 s); passa a guardar as últimas 8 tentativas e, com `tv: true`, monta o layout novo no lugar do `_rodape`. Peças visuais novas ficam em `lib/widgets/ataques_tv.dart`. Bandeiras são PNG em `assets/bandeiras/`.

**Tech Stack:** Flutter web 3.50 (`material_ui`), sem dependência nova.

**Spec:** `docs/superpowers/specs/2026-11-26-tv-ataques-layout-design.md`

## Global Constraints

- Nenhuma dependência nova. Sem emoji como ícone/bandeira.
- Tokens via `tokensOf(context)` (sem cor na mão); textos pt-BR; os dois temas.
- Não mexer em `lib/widgets/heartbeat.dart`. Popup de Acesso (`tv: false`) continua igual.
- Lista ao vivo: **8** linhas. Coluna lateral: **360 px**, **5** itens por top. Bandeira: **20×15 px**, PNG largura 40.

## Review Focus

1. País nulo/desconhecido ou sem PNG → espaço vazio, sem erro de asset → `bandeiraDesconhecidaNaoQuebra` (Task 1).
2. Grupo com `n > 1` mostra `×N`; `n == 1` não mostra → `listaMostraMultiplicador` (Task 2).
3. Login aceito aparece como "Acesso aceito" na lista → `listaMarcaAcessoAceito` (Task 2).
4. Lista não cresce além de 8 com a TV aberta por horas → `listaGuardaSo8` (Task 2).
5. TV abre no tema do usuário e o botão alterna → `tvSegueTemaEAlterna` (Task 3).

---

### Task 1: Bandeiras

**Files:** Create `frontend/tool/baixar_bandeiras.py`, `frontend/assets/bandeiras/*.png`, `frontend/lib/widgets/bandeira.dart`, `frontend/test/bandeira_test.dart`; Modify `frontend/pubspec.yaml` (asset `assets/bandeiras/`).

**Interfaces — Produces:** `class Bandeira extends StatelessWidget { const Bandeira(this.cc, {super.key}); final String? cc; }` → `Image.asset('assets/bandeiras/${cc.toLowerCase()}.png', width: 20, height: 15, errorBuilder: → SizedBox(20×15))`; `cc` nulo/vazio → `SizedBox(20×15)`. `semanticLabel`/`excludeFromSemantics: true` (o nome do país vem ao lado).

- [ ] Script (stdlib): lê os códigos de `backend/nodebeat/dados/paises.csv`, baixa `https://flagcdn.com/w40/<cc>.png` para `frontend/assets/bandeiras/<cc>.png`, avisa os que faltarem. Rodar e commitar os PNG (anotar a fonte e "domínio público" no topo do script).
- [ ] Testes que falham: `bandeiraMostraImagem` (cc 'BR' → `Image` com asset `assets/bandeiras/br.png`); `bandeiraDesconhecidaNaoQuebra` (cc null e cc 'ZZ' → sem exceção, tamanho 20×15).
- [ ] Implementar; `flutter test test/bandeira_test.dart` verde; commit `feat(front): bandeiras dos paises em asset`.

### Task 2: Lista ao vivo e coluna de tops na TV

**Files:** Create `frontend/lib/widgets/ataques_tv.dart`; Modify `frontend/lib/widgets/mapa_ataques.dart` (guardar recentes; layout `tv: true` substitui `_rodape`); Test `frontend/test/mapa_ataques_test.dart`.

**Interfaces — Consumes:** `Bandeira` (Task 1); `Ataque` (`pais` = código, `paisNome`, `ip`, `mkNome`, `via`, `n`, `sucesso`, `quando`); `BlocoPainel` (`topIps` com `pais`/`paisNome`, `topPaises` maps com `pais`/`pais_nome`/`n`, `porVia`). **Produces:** `ListaAoVivo({required List<Ataque> recentes})`, `ColunaTops({required BlocoPainel acesso})`; em `MapaAtaquesState`, `@visibleForTesting List<Ataque> get recentes` (mais novo primeiro, no máximo 8).

- [ ] Testes que falham: `listaAoVivoNaTv` (feed com 1 ataque, `tv: true` → aparece o nome da MK e o país na lista; `tv: false` → sem lista); `listaMostraMultiplicador` (`n: 3` → `×3`; `n: 1` → sem `×1`); `listaMarcaAcessoAceito` (`sucesso: true` → texto "Acesso aceito"); `listaGuardaSo8` (feed devolve 12 ataques → `recentes.length == 8`, o primeiro é o mais novo); `colunaTopsNaTv` (painel com top países → "Top países" e o nome do país; "Top tentativas"; "Top tipos de acesso"). Ajustar os testes do rodapé antigo (`rodapeSoNaTv`, `rodapeAguentaCampoFaltando`) para a coluna nova.
- [ ] Implementar. Layout `tv: true`: `Row[ Expanded(Column[faixas, Expanded(mapa), ListaAoVivo]), SizedBox(width: 360, ColunaTops) ]`. Lista com hora (HH:mm:ss local), serviço com a cor da via, `×N`, bandeira + país + IP, `→` MK, selo `Pilula('Tentativa', cor: fgMuted)` ou `Pilula('Acesso aceito', cor: negative)`. Coluna com 3 blocos de 5 itens (bandeira nas listas de IP e país; barras `GraficoBarras` nos tipos).
- [ ] `flutter test` completo e `flutter analyze` verdes; commit `feat(front): TV com lista ao vivo e coluna de tops`.

### Task 3: Tema escolhido na TV

**Files:** Modify `frontend/lib/screens/mapa_ataques_tv.dart`; Test `frontend/test/mapa_ataques_tv_test.dart`.

- [ ] Teste que falha: `tvSegueTemaEAlterna` (com `themeMode` claro, a TV abre clara; tocar no botão de tema → escura). Remover/substituir `tvTemaEscuro`.
- [ ] Implementar: tirar o `Theme(data: tradeTheme(Brightness.dark))` fixo; `ThemeToggle()` no cabeçalho, ao lado do relógio. Ícone da marca conforme o tema (`nodebeat-icon-light.png`/`-dark.png`, se existirem em `assets/brand/`).
- [ ] `flutter test` e `flutter analyze` verdes; commit `feat(front): tema claro/escuro escolhido na TV`.

### Task 4: Revisão final e deploy (com o dono)

- [ ] Revisão da branch; deploy do `web` só com confirmação do dono; conferir no Chrome a TV nos dois temas.

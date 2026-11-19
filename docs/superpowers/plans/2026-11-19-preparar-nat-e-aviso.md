# Preparar MK: NAT 18729 e aviso de colagem — plano

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** os scripts da página Preparar MK criam o NAT 18729→8729, e a página explica o que fazer quando a colagem quebra.
**Architecture:** só no frontend: `frontend/lib/mk_script.dart` e `frontend/lib/screens/preparar_mk.dart`.
**Tech Stack:** Flutter/Dart, flutter_test.
**Spec:** `docs/superpowers/specs/2026-11-19-preparar-nat-e-aviso-design.md`

## Global Constraints
- Scripts só em ASCII. Script curto com linhas ≤ 80 colunas. Comentário da regra: `monitor-api-alt`.

## Review Focus
- A regra é idempotente: rodar o script duas vezes não deixa duas regras `monitor-api-alt` (remove antes de criar, nos dois scripts).

---

### Task 1: NAT nos scripts e aviso na página
**Files:** `frontend/lib/mk_script.dart`, `frontend/lib/screens/preparar_mk.dart`, `frontend/test/mk_script_test.dart`, `frontend/test/preparar_mk_test.dart`

- [ ] Testes que falham, em `mk_script_test.dart`:
  - o Preparar contém `/ip firewall nat remove [find where comment="monitor-api-alt"]` antes de `in-interface=$wan protocol=tcp dst-port=18729 action=redirect to-ports=8729`;
  - o script curto contém o mesmo remove, `dst-port=18729` e `to-ports=8729`, `comment=monitor-api-alt` e nenhum `in-interface`;
  - o Desfazer contém o remove.
  - Em `preparar_mk_test.dart`, a página mostra um texto com `invalid value`.
- [ ] `flutter test`: os testes novos falham.
- [ ] Implementar.
- [ ] `flutter test`: tudo passa. Commit `feat(preparar): NAT 18729 para a api-ssl e aviso de colagem quebrada`.

### Task 2: deploy do web no CT 119 e conferência da página

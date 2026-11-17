# Preparar MK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Página "Preparar MK" com um script RouterOS que se cola no terminal da MK sem preencher nada.

**Architecture:** O backend só expõe dois IPs do `.env` (`GET /api/preparar-mk`). O front gera a senha e monta o
script (gerador puro em Dart, testado); a MK descobre versão, WAN, IP público e IP do túnel na hora.

**Tech Stack:** FastAPI + pytest (backend/.venv), Flutter web (C:/src/flutter), RouterOS script (v6.49 e v7.24).

**Spec:** `docs/superpowers/specs/2026-11-17-preparar-mk-design.md`

## Global Constraints

- Script **100% ASCII** (strings de `:put`/`:error` sem acento): terminal da MK.
- Todo o script dentro de **um bloco `{ ... }`** (sem isso `:local` some a cada linha no terminal).
- Nenhuma alteração antes de todas as descobertas e checagens (`:error` aborta o bloco).
- Linha com `available-from=` só via `[:parse "..."]` (a v6 rejeita o parâmetro ao ler o script).
- Grupo `monitor`: `policy=read,api,reboot`. `/user ... address=` (não muda na 7.24).
- Senha: 20 caracteres `[A-Za-z0-9]`, `Random.secure()`; nunca enviada ao servidor.
- IPs reais nunca no repositório: só em `deploy/.env` do CT 119.
- Trade UI: tokens, temas claro e escuro, `tabular-nums` não se aplica (sem valores financeiros).

## Review Focus

- MK com certificado `monitor-api` já existente: reaproveitar (não recriar), senão o pin do NodeBeat quebra → Task 2 testa que `/certificate add` fica dentro de `:if ([:len [/certificate find ...]] = 0)`.
- Re-rodar numa MK já cadastrada troca a senha → script imprime aviso "atualize a senha no cadastro" → Task 2 testa a string.
- Chain input vazia: `place-before=0` falha → Task 2 testa o desvio `:if ([:len [/ip firewall filter find]] > 0)`.
- `.env` sem as variáveis → página mostra o que falta e não mostra script → Task 3 testa.
- Gateway estático na v7 (`192.168.0.1%ether1`) e `gateway-status` da v6 (`... reachable via  ether1`) → Task 2 testa que o script trata `%` e `via `, e confere que a interface existe antes de seguir.

---

### Task 1: Backend — IPs do servidor

**Files:**
- Modify: `backend/nodebeat/config.py`, `backend/nodebeat/api.py`, `deploy/.env.example`
- Test: `backend/tests/test_api_mks.py`, `backend/tests/test_app_from_env.py`

**Interfaces:**
- Produces: `Settings.ip_origem: str | None`, `Settings.ip_publico_sede: str | None` (env `NODEBEAT_IP_ORIGEM`,
  `NODEBEAT_IP_PUBLICO_SEDE`, opcionais, IPv4 validado → `RuntimeError("NODEBEAT_IP_ORIGEM inválida")`).
  `GET /api/preparar-mk` (logado) → `{"ip_origem": str|None, "ip_publico_sede": str|None}`.

- [ ] Testes: `test_preparar_mk_devolve_ips` (Settings com os dois → JSON igual), `test_preparar_mk_sem_env_devolve_null`,
  `test_preparar_mk_exige_login` (anon → 401), `test_ip_origem_invalido_falha` (env `"abc"` → RuntimeError).
- [ ] Rodar: `.venv/Scripts/python -m pytest -q` → falham.
- [ ] Implementar (campos com default `None` no fim do dataclass).
- [ ] Rodar suíte → passa. `.env.example`: as duas linhas com placeholders `<IP_ORIGEM>`/`<IP_PUBLICO_SEDE>`.
- [ ] Commit `feat(backend): IPs do servidor para o script de preparo da MK`.

### Task 2: Gerador do script (Dart puro)

**Files:**
- Create: `frontend/lib/mk_script.dart`
- Test: `frontend/test/mk_script_test.dart`

**Interfaces:**
- Produces: `String gerarSenha([Random? rng])`; `String scriptPreparar({required String ipOrigem, required String ipPublicoSede, required String senha})`;
  `const String scriptLiberarReinicio = '/user group set monitor policy=read,api,reboot';`; `const String scriptDesfazer`.

- [ ] Testes: senha tem 20 chars `[A-Za-z0-9]` e duas chamadas diferem; script contém os 3 valores e nenhum `<`/`>` de
  placeholder; todo char ≤ 0x7F; começa com `{` e chaves balanceadas; índice do último `:error` < índice do primeiro
  `/certificate add`; `available-from` só aparece dentro de `[:parse`; contém `immediate-gw`, `gateway-status`, `"%"`,
  `"via "`; `/certificate add name=monitor-api` dentro de `:if ([:len [/certificate find`; desvio de `place-before=0`;
  aviso de senha trocada; `scriptDesfazer` remove regra, usuário, grupo, certificados e desliga api-ssl.
- [ ] Rodar `flutter test test/mk_script_test.dart` → falha.
- [ ] Implementar. Ordem do script: (1) variáveis; (2) versão → `maior`/`menor` lendo dígitos até não-dígito, `novo = maior>7 || (maior=7 && menor>=24)`;
  (3) rotas `dst-address=0.0.0.0/0 && active`: 0 ou >1 → `:error` "... Nada foi alterado."; WAN = v7 `immediate-gw` após `%`,
  v6 `gateway-status` após `via ` (sem espaços) ou 1ª palavra; interface inexistente → `:error`; (4) IP público = endereço da WAN
  sem `/n`; IP do túnel = endereço da MK dentro do `src-address` de uma policy IPsec não-template (em `:do {} on-error={}`;
  falhou → "nao encontrado"); (5) aplicar: certificados só se não existem, esperando `private-key` até 30 s (senão `:error`);
  api-ssl (`[:parse]` com `available-from` se `novo`, senão `address=`); grupo add/set; usuário add/set; regra ICMP
  remove+add; (6) `:put` com versão, WAN e "Cadastro no NodeBeat -> IP do tunel / IP publico / usuario monitor".
- [ ] Rodar → passa. `flutter analyze` limpo.
- [ ] Commit `feat(frontend): gerador do script de preparo da MK`.

### Task 3: Tela "Preparar MK"

**Files:**
- Create: `frontend/lib/screens/preparar_mk.dart`
- Modify: `frontend/lib/api/client.dart` (`Future<PrepararMkInfo> prepararMk()`), `frontend/lib/main.dart` (rota `/preparar-mk`),
  `frontend/lib/screens/dashboard.dart` (IconButton ao lado de Faixas, tooltip "Preparar MK", `aria`=tooltip)
- Test: `frontend/test/preparar_mk_test.dart`

**Interfaces:**
- Consumes: Task 1 (JSON), Task 2 (funções).
- Produces: `PrepararMkScreen({required ApiClient api})`.

- [ ] Testes: mostra script com os dois IPs e a senha; "Copiar" põe o script no clipboard (mock do canal
  `SystemChannels.platform`, `Clipboard.setData`) e mostra "Script copiado"; "Gerar outra senha" troca a senha no script;
  sem env → texto com `NODEBEAT_IP_ORIGEM` e sem botão Copiar; seção do reinício e do desfazer com seus Copiar;
  renderiza nos temas claro e escuro; ícone do painel abre `/preparar-mk`.
- [ ] Rodar → falha. Implementar: passos numerados (1 copiar e colar no Winbox → New Terminal; 2 conferir a saída;
  3 cadastrar no painel com IP do túnel, IP público, usuário `monitor` e a senha mostrada); script em card interno
  `radius-md`, fonte mono, selecionável. Rodar → passa; `flutter analyze` limpo.
- [ ] Commit `feat(frontend): página Preparar MK`.

### Task 4: Docs, deploy e validação real

**Files:**
- Delete: `deploy/routeros-monitor-user.rsc`
- Modify: `deploy/README.md` (seção da MK aponta para a página; menciona as duas variáveis)

- [ ] Grep no repo por `routeros-monitor-user` → só sobra o que for histórico (specs/plans antigos ficam).
- [ ] Suítes completas back e front verdes; grep de dados reais no diff; commit `docs: preparo da MK pela página`.
- [ ] Deploy no CT 119 (com aprovação): adicionar as duas variáveis ao `deploy/.env` do CT, `git archive` + `compose up -d --build`.
- [ ] Validação pelo usuário: colar o script na MK de teste (re-rodar = senha nova → atualizar o cadastro) e, se houver, numa v6.
  Conferir saída, painel "No ar" e `/user group print where name=monitor`.

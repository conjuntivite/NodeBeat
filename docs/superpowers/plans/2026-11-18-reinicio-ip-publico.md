# Reinício pelo IP público Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O botão Reiniciar tenta pelo túnel e, se não conseguir conectar, reinicia a MK pelo IP público.

**Architecture:**
- **Backend:** `routeros._erro` passa a separar as falhas de rede (`SemConexao`), e `POST /api/mks/{id}/reiniciar` faz o fallback e devolve o caminho usado.
- **MK:** as três travas da API-SSL (firewall, serviço e usuário `monitor`) passam a aceitar os IPs públicos da sede. Isso vale para o Preparar MK completo e para um script curto destinado às MKs já cadastradas.

**Tech Stack:**
- Backend: FastAPI + pytest (`backend/.venv`).
- Frontend: Flutter web (`C:/src/flutter`).
- RouterOS script: v6 ≥ 6.43 e v7.

**Spec:** `docs/superpowers/specs/2026-11-18-reinicio-ip-publico-design.md`

## Global Constraints

- **Quando o fallback roda:** só em `SemConexao`, que é timeout ou conexão recusada. Login recusado, falha de TLS ou certificado diferente e falta de permissão **não** tentam o IP público.
- **Timeout:** 5 s por tentativa (`routeros.reboot` atual).
- **Resposta de sucesso:** `200 {"via": "tunel" | "publico"}`.
- **Erro com os dois caminhos falhando:** 502 `{"detalhe": "Túnel: <x>. IP público: <y>"}`.
- **Avisos do painel:** "Reinício enviado pelo túnel" e "Reinício enviado pelo IP público".
- **Regra de firewall:** `comment="monitor-api-wan"`, `chain=input protocol=tcp dst-port=8729 src-address-list=nodebeat-sede action=accept`, antes da `monitor-icmp`. A `monitor-api` (só IPsec) não muda.
- **Lista de endereços:** `<ipOrigem>/32` mais cada IP da sede `/32`, separados por vírgula, no `address` (ou `available-from` na v7 ≥ 7.24, via `[:parse (...)]`) do serviço api-ssl e no `address` do usuário `monitor`.
- **Script RouterOS:**
  - 100% ASCII;
  - linhas de até 110 colunas;
  - num bloco `{ ... }`;
  - parâmetro só de uma versão sempre dentro de `[:parse (...)]`;
  - nunca troca a senha.
- **Repositório público:** só IPs de documentação nos testes.
- **Dependências:** nenhuma nova.
- **Ações externas:** deploy e push só com aprovação do usuário. Nada é colado em MK real sem o usuário.

## Review Focus

1. **MK sem `ip_publico`, ou com ele vazio:** o reinício fica só no túnel e devolve o erro do túnel. → Task 1 `test_reiniciar_sem_ip_publico_so_tunel`.
2. **`NODEBEAT_IPS_PUBLICOS_SEDE` vazio:** o script curto não deve ser gerado, porque abriria só para o `ipOrigem` e a regra WAN ficaria inútil. A página mostra um aviso. → Task 2 `test_liberar_publico_sem_ips_sede`.
3. **MK sem a regra `monitor-icmp`** (preparada à mão, ou firewall diferente): a regra nova não pode falhar no `place-before`. Usa a mesma lógica de "primeira regra input não dinâmica, senão no fim". → Task 2 assertion.
4. **Duplo clique no Reiniciar:** fora do escopo. O diálogo de confirmação já existe e não muda.
5. **Exceção inesperada no 2º caminho:** continua o 502 "Resposta inesperada da API", sem ecoar segredo. → Task 1 `test_reiniciar_publico_excecao_inesperada`.

---

### Task 0: Teste real dos comandos RouterOS (manual, com o usuário)

- [ ] **Step 1:** Montar à mão, para a W96 (v6) e para a NDTV (v7), o bloco das três travas descrito na Task 2, com os IPs reais. Fica só na conversa, nunca no repo. O usuário cola.
- [ ] **Step 2:** No CT 119, rodar `openssl s_client -connect <ip_publico>:8729 </dev/null` para as duas. O esperado é o handshake mostrar o certificado `monitor-api`.
- [ ] **Step 3:** No CT, com `docker compose exec api python -c` chamando `routeros.list_interfaces(<ip_publico>, ...)`, que só lê, confirmar o login pelo IP público. A senha vem do cadastro, decifrada dentro do container, sem passar pelo chat.
- [ ] **Step 4:** Se algum comando der erro em v6 ou v7 (lista com vírgulas em `address=`, por exemplo), ajustar a forma na Task 2 antes de codar.

### Task 1: Fallback no backend

**Files:**
- Modify: `backend/nodebeat/routeros.py` (`_erro`, nova classe)
- Modify: `backend/nodebeat/api.py` (`reiniciar`)
- Test: `backend/tests/test_routeros.py`, `backend/tests/test_api_mks.py`

**Interfaces:**
- Produces:
  - `class SemConexao(RouterOsError)`;
  - `_erro` devolve `SemConexao` para `TimeoutError` e para `OSError`/`LibRouterosError` que não sejam TLS. As mensagens continuam as atuais.
  - `POST /api/mks/{id}/reiniciar` → `200 {"via": ...}`.

- [ ] **Step 1: Testes que falham**
  - `test_routeros.py`: `isinstance(_erro(TimeoutError(), False), SemConexao)`, `isinstance(_erro(ConnectionRefusedError(), True), SemConexao)`, `not isinstance(_erro(TrapError(...), True), SemConexao)` e `not isinstance(_erro(ssl.SSLError(...), False), SemConexao)`.
  - `test_api_mks.py`, com `monkeypatch` de `routeros.reboot` registrando os hosts chamados:
    - `test_reiniciar_pelo_tunel`: 200, `via == "tunel"`, um host só (`ip_tunel`).
    - `test_reiniciar_cai_no_publico`: o 1º lança `SemConexao("API sem resposta (timeout)")`, o 2º funciona. Espera `via == "publico"`, hosts `[ip_tunel, ip_publico]`, e a janela `REINICIO` e o histórico gravados como hoje.
    - `test_reiniciar_login_recusado_nao_tenta_publico`: `RouterOsError("Login recusado (usuário ou senha)")` → 502 com esse detalhe e um host só.
    - `test_reiniciar_dois_caminhos_falham`: os dois lançam `SemConexao` → 502 com `detalhe == "Túnel: API sem resposta (timeout). IP público: Conexão com a API recusada"`.
    - `test_reiniciar_sem_ip_publico_so_tunel`: MK com `ip_publico=""` inserida direto no db → um host só e 502 com o detalhe do túnel.
    - `test_reiniciar_publico_excecao_inesperada`: o 2º lança `ValueError("segredo")` → 502 "Resposta inesperada da API", e o corpo não contém `segredo`.
  - Ajustar os testes existentes `test_reiniciar_chama_a_mk_e_registra` (agora 200) e `test_reiniciar_falha_devolve_502_sem_janela`.
- [ ] **Step 2:** `cd backend && .venv/Scripts/python -m pytest tests/test_routeros.py tests/test_api_mks.py -q` → FAIL.
- [ ] **Step 3:** Implementar. Um helper local `_reboot(host)` faz o `asyncio.to_thread`. O túnel vai primeiro. Em `SemConexao` e com `mk.get("ip_publico")`, tenta o público. A janela e o histórico só são gravados no sucesso, e o detalhe do histórico ganha " pelo IP público" quando `via == "publico"`.
- [ ] **Step 4:** Suíte backend inteira → PASS.
- [ ] **Step 5:** Commit `feat(reinicio): cai no IP público quando o túnel não conecta`.

### Task 2: Painel e scripts

**Files:**
- Modify: `frontend/lib/api/client.dart` (`reiniciar` → `Future<String>`, devolve `via`)
- Modify: `frontend/lib/screens/mk_detail.dart` (aviso conforme `via`)
- Modify: `frontend/lib/mk_script.dart` (`_modelo`, `scriptDesfazer`, nova função)
- Modify: `frontend/lib/screens/preparar_mk.dart` (bloco novo ao lado de "Liberar reinício")
- Test: `frontend/test/mk_reiniciar_test.dart`, `frontend/test/mk_script_test.dart`, `frontend/test/preparar_mk_test.dart`

**Interfaces:**
- Consumes: resposta da Task 1 e `PrepararMkInfo` (`ipOrigem`, `ipsSede`), que já existe.
- Produces: `String scriptLiberarReinicioPublico({required String ipOrigem, required List<String> ipsSede})`.

- [ ] **Step 1: Testes que falham**
  - `mk_reiniciar_test.dart`: API devolvendo `{"via":"publico"}` → snackbar "Reinício enviado pelo IP público"; `{"via":"tunel"}` → "Reinício enviado pelo túnel".
  - `mk_script_test.dart`, com `scriptLiberarReinicioPublico(ipOrigem: '192.0.2.53', ipsSede: ['203.0.113.10','203.0.113.11'])`:
    - contém `192.0.2.53/32,203.0.113.10/32,203.0.113.11/32`, `comment="monitor-api-wan"`, `src-address-list=nodebeat-sede`, `dst-port=8729`, `available-from=` dentro de `[:parse (` e `/user set monitor address=`;
    - recria a address-list `nodebeat-sede` com os dois IPs;
    - **não** contém `password`;
    - tem fallback de posição: se não existir `monitor-icmp`, usa a primeira regra input não dinâmica ou o fim da lista;
    - ASCII e linhas de até 110 colunas.
  - `scriptPreparar(...)`: as linhas do api-ssl e do `/user add|set monitor` usam a lista com os IPs da sede, e existe a regra `monitor-api-wan`.
  - `scriptDesfazer` contém `remove [find where comment="monitor-api-wan"]`.
  - `preparar_mk_test.dart`:
    - o bloco "Liberar reinício pelo IP público" aparece com botão copiar;
    - `test_liberar_publico_sem_ips_sede`: com `ips_publicos_sede: []`, mostra "Configure NODEBEAT_IPS_PUBLICOS_SEDE no servidor" e nenhum script.
- [ ] **Step 2:** `cd frontend && C:/src/flutter/bin/flutter test test/mk_reiniciar_test.dart test/mk_script_test.dart test/preparar_mk_test.dart` → FAIL.
- [ ] **Step 3:** Implementar.
  - **Versão:** detectada no script curto como no `_modelo` (`novo` = v7 ≥ 7.24).
  - **Lista:** montada no Dart e injetada como texto literal no script curto. No `_modelo`, vira um marcador `@LISTA_API@` substituído pelo Dart. `ipOrigem` já é literal lá.
  - **Bloco das travas:** uma `const` única, reaproveitada pelas duas funções. As formas confirmadas na Task 0 têm prioridade sobre este plano.
- [ ] **Step 4:** `flutter test` (suíte inteira) e `flutter analyze` → sem falhas.
- [ ] **Step 5:** Commit `feat(reinicio): scripts liberam a api-ssl para a sede pela WAN e aviso mostra o caminho`.

### Task 3: Deploy e teste real (com aprovação do usuário)

- [ ] **Step 1:** Revisão final da branch (um revisor, no modelo mais capaz).
- [ ] **Step 2:** Grep de dados reais no diff. Depois `git archive HEAD | ssh ... tar -x`, `up -d --build api web` e conntrack, como no README (o `syslog` não muda).
- [ ] **Step 3:** O usuário aplica "Liberar reinício pelo IP público" numa MK de teste escolhida por ele. Com o túnel dela desligado, na hora que ele decidir, clicar em Reiniciar e conferir o aviso "pelo IP público".
- [ ] **Step 4:** Push e merge na `main` (aprovados pelo usuário).

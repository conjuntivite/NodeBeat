# Reinício pelo IP público na porta alternativa — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** quando o IP público não conecta na 8729, o botão Reiniciar tenta a 18729.

**Architecture:** `routeros.reboot` passa a aceitar a porta. A rota `reiniciar` tenta, pelo IP público, a 8729 e, só em `SemConexao`, a 18729.

**Tech Stack:** Python, FastAPI, librouteros, pytest.

**Spec:** `docs/superpowers/specs/2026-11-19-reinicio-porta-alternativa-design.md`

## Global Constraints
- Porta padrão `8729`; porta alternativa `18729`. Usar só no caminho do IP público.
- Só `routeros.SemConexao` aciona uma nova tentativa. Login, certificado e permissão não acionam.
- Mensagem de falha total: `Túnel: <erro do túnel>. IP público: <erro da última tentativa>`.
- Resposta e histórico iguais aos de hoje: `{"via": "publico"}` e o detalhe `Solicitado por <usuário> pelo IP público`.

## Review Focus
- O IP público recusa o login na 8729 (`RouterOsError`, não `SemConexao`). Nesse caso não deve tentar a 18729. Teste `test_reiniciar_publico_login_recusado_nao_tenta_alternativa`.
- A 18729 levanta exceção inesperada. A resposta continua `Resposta inesperada da API`, sem vazar o texto. Os testes atuais já cobrem esse caminho.

---

### Task 1: porta no reboot e segunda tentativa na rota

**Files:**
- Modify: `backend/nodebeat/routeros.py` (`_com_api`, `reboot`)
- Modify: `backend/nodebeat/api.py` (`reiniciar`)
- Test: `backend/tests/test_routeros.py`, `backend/tests/test_api_mks.py`

**Interfaces:**
- Produces: `routeros.reboot(host, user, password, pinned_sha256, porta: int = 8729) -> None` e `routeros.PORTA_API_ALT = 18729`.

- [ ] **Step 1: testes que falham**
  - `test_routeros.py::test_reboot_usa_porta_informada`: com `librouteros.connect` trocado por um fake que guarda `port`, `routeros.reboot("h","u","p",None, porta=18729)` conecta com `port == 18729`, e sem `porta` conecta com `8729`.
  - `test_api_mks.py`: `_reboot_fake` passa a registrar `(host, kw.get("porta", 8729))`. Ajuste as asserções de `hosts` que já existem.
  - `test_reiniciar_cai_na_porta_alternativa`: as respostas são túnel `SemConexao`, público na 8729 `SemConexao`, público na 18729 `None`. O resultado é `200 {"via":"publico"}`, com chamadas `[("10.8.0.2",8729),("8.8.4.4",8729),("8.8.4.4",18729)]`.
  - `test_reiniciar_dois_caminhos_falham`: passa a ter 3 falhas `SemConexao`. A última é `"Conexão com a API recusada"`, e a mensagem esperada é a mesma de hoje.
  - `test_reiniciar_publico_login_recusado_nao_tenta_alternativa`: túnel `SemConexao` e público `RouterOsError("Login recusado (usuário ou senha)")` resultam em `502` com o detalhe `Túnel: API sem resposta (timeout). IP público: Login recusado (usuário ou senha)`, e 2 chamadas.
- [ ] **Step 2:** `cd backend && python -m pytest tests/test_routeros.py tests/test_api_mks.py -q`. Os testes novos devem falhar.
- [ ] **Step 3:** implementar. `_com_api` recebe `porta` e a repassa como `port=`. Na rota, o caminho do IP público vira um laço sobre `(8729, PORTA_API_ALT)` que só continua em `SemConexao`.
- [ ] **Step 4:** `cd backend && python -m pytest -q`. Tudo deve passar.
- [ ] **Step 5:** commit `feat(reinicio): tenta a porta 18729 pelo IP público quando a 8729 não conecta`.

### Task 2: deploy e conferência
- [ ] Deploy no CT 119 pelo comando da memória (`git archive` + `docker compose up -d --build api`).
- [ ] Rodar o reinício da DONA IOLANDA só com o ok do usuário. Quem clica é o usuário. O teste do caminho público, se for pedido, segue o roteiro de bloquear o túnel para o container da api.

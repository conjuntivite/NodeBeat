# Alterações nas MKs (peer IPsec e liberar porta) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O NodeBeat passa a escrever nas MKs com um usuário próprio (`nodebeat-rw`): trocar o peer address do IPsec e criar/remover port forwards para IPs internos.

**Architecture:** Lógica que fala com a MK fica em `backend/nodebeat/alteracoes.py`, em funções que recebem o objeto `api` do librouteros (testáveis com uma API falsa). `routeros.sessao` abre a conexão fixada; `api.py` ganha a cascata de caminhos (`_na_mk`), usada também pelo Reiniciar. No front, o script do Preparar MK cria o usuário; o cadastro guarda a senha cifrada; dois cartões novos no detalhe da MK.

**Tech Stack:** FastAPI + Motor + librouteros (pytest, httpx, mongomock-motor, fakeredis); Flutter web (`material_ui`, `http/testing`).

**Spec:** `docs/superpowers/specs/2026-11-26-alteracoes-mk-design.md`

## Global Constraints

- Usuário da MK fixo: `nodebeat-rw`, grupo `nodebeat-rw`, `policy=read,write,api`. `monitor` não muda.
- Senha de escrita: `senha_rw_cifrada` no Mongo (`crypto.encrypt`, `settings.secret_key`); nunca em resposta, log ou mensagem de erro (`str(e)` cru nunca vai para o cliente).
- Comentário das regras criadas: `nodebeat:<descricao>`; descrição 1–40 caracteres, só `[A-Za-z0-9 ._-]`, única por MK (sem diferenciar maiúsculas). Regra sem o prefixo nunca é alterada nem removida.
- Portas externas reservadas: 8729, 18729 (`routeros.PORTA_API_ALT`), 8291, 18291 e as portas dos serviços da MK (`inventario.servicos`, ativos ou não).
- Caminho: leitura e port forward = túnel → público 8729 → público 18729; troca de peer = público 8729 → público 18729 → túnel. Só `routeros.SemConexao` pula para o próximo.
- Sem `senha_rw_cifrada`: rotas de escrita respondem **409** `{"detail": "Para alterar esta MK pelo NodeBeat, aplique o script 'permitir alterações' da página Preparar MK e preencha a senha no cadastro."}`.
- Scripts RouterOS: só ASCII, num bloco `{}`, linhas ≤ 110 colunas, a senha é gerada no navegador (`gerarSenha()`).
- Nunca commitar IPs, domínio ou nomes reais: testes e docs usam IPs de exemplo (`8.8.4.4`, `10.8.0.2`, `192.168.88.x`, `203.0.113.x`).
- Front: mesmos tokens/componentes das telas atuais (`TradeCard`, `tokensOf`, `TradeType`), temas claro e escuro.
- Comandos: backend `cd backend && .venv/Scripts/python -m pytest -q`; front `cd frontend && flutter test` e `flutter analyze`.

## Review Focus

1. **Conexão cai logo depois do `peer/set` (pelo túnel)** → resposta 200 com `confirmado: false`, e não 502. Teste em Task 3.
2. **Porta externa dentro de uma faixa ou lista de um NAT existente** (`dst-port=8000-8100` ou `80,8080`) → recusa com o uso listado. Teste em Task 4.
3. **"ambos" e a segunda regra falha** → a primeira é removida e nada fica na MK. Teste em Task 4.
4. **Senha `nodebeat-rw` errada ou grupo sem `write`** → 502 com "Usuário nodebeat-rw sem permissão de escrita" ou "Login recusado", **sem** pular para outro caminho. Teste em Task 2.
5. **Editar a MK sem tocar na senha de alterações** → a senha continua; só `remover_rw: true` apaga. Teste em Task 1.

---

### Task 1: Senha de alterações no cadastro da MK (backend)

**Files:**
- Modify: `backend/nodebeat/api.py` (`MkIn`, `criar`, `obter`, `alterar`)
- Test: `backend/tests/test_api_mks.py`

**Interfaces:**
- Produces: `MkIn.senha_rw: str = ""`, `MkIn.remover_rw: bool = False`; `GET /api/mks/{id}` devolve `tem_rw: bool`; Mongo `senha_rw_cifrada`; constante `api.USUARIO_RW = "nodebeat-rw"`; helper interno `_senha_rw(mk: dict) -> str` que levanta `HTTPException(409, <mensagem dos Global Constraints>)` quando não há senha.

- [ ] **Step 1: Testes que falham**
  - `test_senha_rw_cifrada_e_tem_rw`: POST com `senha_rw="rw-segredo-1"` → Mongo `senha_rw_cifrada` decifra para `"rw-segredo-1"`; GET devolve `tem_rw is True` e `sem_senha(body)`.
  - `test_sem_senha_rw_tem_rw_false`: POST sem o campo → `tem_rw is False`, sem chave `senha_rw_cifrada`.
  - `test_put_sem_senha_rw_mantem` (Review Focus 5): cria com `senha_rw`, PUT com `{**MK, "nome": "Outro"}` → `senha_rw_cifrada` igual à anterior.
  - `test_put_remover_rw_apaga`: PUT com `remover_rw=True` → chave sumiu e `tem_rw is False`.
  - `remover_rw` e `senha_rw` nunca são gravados como campos (`"remover_rw" not in doc`, `"senha_rw" not in doc`).
- [ ] **Step 2:** `cd backend && .venv/Scripts/python -m pytest tests/test_api_mks.py -q` → os novos falham.
- [ ] **Step 3:** Implementar. `_tunel_ok` passa a excluir `senha`, `senha_rw`, `remover_rw` do `model_dump`. `remover_rw` → `$unset` (ou `store.update_mk` com o campo `None` e o GET tratando `None` como ausente; escolha do implementador, desde que o teste de "chave sumiu"/`tem_rw False` passe).
- [ ] **Step 4:** Suite inteira do backend verde.
- [ ] **Step 5:** Commit `feat(api): senha de alteracoes (nodebeat-rw) no cadastro da MK`.

### Task 2: Cascata de caminhos e sessão genérica

**Files:**
- Modify: `backend/nodebeat/routeros.py`, `backend/nodebeat/api.py` (rota `reiniciar`)
- Test: `backend/tests/test_api_mks.py` (testes atuais do reiniciar continuam iguais), `backend/tests/test_routeros.py`

**Interfaces:**
- Produces:
  - `routeros.sessao(host: str, user: str, password: str, pinned_sha256: str | None, usar: Callable[[api], T], porta: int = 8729, timeout: float = 10.0) -> T`: `_com_api` com `usar(api)` (sem o `seen`). Dentro de `usar`, `TrapError` com "permission" vira `RouterOsError("Usuário nodebeat-rw sem permissão de escrita")` quando `user == "nodebeat-rw"`, senão o texto atual de `_erro`.
  - Em `api.py`: `async def _na_mk(mk: dict, chamar: Callable[..., T], publico_primeiro: bool = False) -> tuple[T, str]`. `chamar(host, **kw)` é síncrono, roda em `asyncio.to_thread`; `kw` é `{}` ou `{"porta": routeros.PORTA_API_ALT}`. Devolve `(resultado, via)` com `via in ("tunel", "publico")`.
- Regra da cascata (preserva as mensagens atuais):
  - passos = `[("tunel", ip_tunel, {}), ("publico", ip_publico, {}), ("publico", ip_publico, {"porta": 18729})]`, sem os de `publico` quando não há `ip_publico`; com `publico_primeiro`, os de `publico` vêm antes;
  - `SemConexao` guarda `erros[rotulo] = detalhe` (o mesmo rótulo sobrescreve) e segue; outro `RouterOsError` para;
  - se mais de um rótulo falhou, a mensagem é `". ".join(f"{nome}: {detalhe}")` com nomes `Túnel`/`IP público` na ordem tentada; senão, o `detalhe` sozinho.

- [ ] **Step 1: Testes que falham**
  - `test_na_mk_publico_primeiro_ordem`: fake que levanta `SemConexao` sempre → hosts tentados `[("8.8.4.4", 8729), ("8.8.4.4", 18729), ("10.8.0.2", 8729)]` e 502 `"IP público: <detalhe>. Túnel: <detalhe>"`. Exercitar por uma rota da Task 3, ou chamar `_na_mk` direto se o implementador expuser como função de módulo (preferível: `_na_mk` no nível do módulo em `api.py`; ele não depende de `settings`).
  - `test_sessao_permissao_rw` (Review Focus 4): `usar` que levanta `TrapError("not enough permissions (9)")` com `user="nodebeat-rw"` → `RouterOsError` com a mensagem exata; testar `sessao` com `librouteros.connect` trocado por monkeypatch que devolve uma API falsa.
- [ ] **Step 2:** Rodar → falham.
- [ ] **Step 3:** Implementar `sessao` e `_na_mk`; reescrever `reiniciar` com `_na_mk` (o registro em Redis/histórico fica igual).
- [ ] **Step 4:** Todos os `test_reiniciar_*` existentes passam **sem alteração** + os novos.
- [ ] **Step 5:** Commit `refactor(api): cascata de caminhos ate a MK reutilizavel`.

### Task 3: Trocar o peer do IPsec (backend)

**Files:**
- Create: `backend/nodebeat/alteracoes.py`, `backend/tests/test_alteracoes.py`
- Modify: `backend/nodebeat/api.py`, `backend/nodebeat/rules.py` (`Event.evento` aceita `"alteracao"`)
- Test: `backend/tests/test_api_alteracoes.py` (novo; fixtures copiadas do `test_api_mks.py`)

**Interfaces:**
- Consumes: `routeros.sessao`, `_na_mk`, `_senha_rw`, `USUARIO_RW` (Tasks 1–2).
- Produces:
  - `alteracoes.ler_peers(api) -> list[dict]`: cada item `{"id", "nome", "endereco", "desativado", "comentario", "por_dominio"}` (`nome` pode ser `None` na v6; `por_dominio` = `endereco` não é IP nem IP/prefixo).
  - `alteracoes.trocar_peer(api, peer_id: str, novo: str) -> dict`: devolve `{"antigo", "novo", "confirmado": bool, "policies": [ids alteradas], "policies_erro": [ids]}`. `KeyError`→ rota 404 se o `.id` não existe; `ValueError` se `novo == antigo`.
  - `GET /api/mks/{id}/ipsec/peers` → `{"peers": [...], "via"}` (usuário `monitor`, cascata normal).
  - `PUT /api/mks/{id}/ipsec/peers/{peer_id}` body `{"endereco": str}` → `{...trocar_peer, "via"}` (usuário `nodebeat-rw`, `publico_primeiro=True`). `endereco` IPv4 `is_global`, senão 422. MK `sem_ipsec` → 409 "MK sem IPsec".

- [ ] **Step 1: Fixtures reais.** Pegar o formato de `/ip ipsec peer print detail` e `/ip ipsec policy print detail` de uma v7 (NDTV, SSH read-only, ver memória do projeto) e da documentação da v6. Anotar no topo do `test_alteracoes.py` os nomes de campo confirmados (`address`, `peer`, `sa-dst-address`, `.id`), com IPs trocados por exemplos. Se a v7 não mostrar `peer` na policy, parar e avisar (a regra v6/v7 do spec depende disso).
- [ ] **Step 2: Testes que falham** (`test_alteracoes.py`, com `FakeApi`: `__call__(cmd, **kw)` grava `(cmd, kw)` e devolve linhas pré-carregadas por comando):
  - `test_ler_peers_dominio`: peer `address="vpn.exemplo.com"` → `por_dominio True`; `"203.0.113.1/32"` → `False`.
  - `test_trocar_peer_v7_nao_mexe_policy`: policy com `peer` → nenhum `/ip/ipsec/policy/set`.
  - `test_trocar_peer_v6_atualiza_sa_dst`: policy sem `peer`, `sa-dst-address` = antigo → `set` com `sa-dst-address=novo`; outra policy com outro endereço fica intacta.
  - `test_trocar_peer_set_policy_falha`: `TrapError` no set da policy → `policies_erro == [id]` e o peer trocado.
  - `test_trocar_peer_conexao_cai_depois_do_set` (Review Focus 1): o print de confirmação levanta `OSError` → `confirmado False`, sem exceção.
  - `test_trocar_peer_igual_valueerror`, `test_trocar_peer_id_inexistente_keyerror`.
- [ ] **Step 3: Testes de rota que falham** (`test_api_alteracoes.py`, `routeros.sessao` trocado por fake que chama `usar(FakeApi)`):
  - PUT sem `senha_rw` → 409 com a mensagem exata; com IP privado → 422; PUT ok → 200, `via == "publico"`, histórico com `evento == "alteracao"` e detalhe `"Peer IPsec <nome ou id>: 203.0.113.1 → 203.0.113.2, por ana pelo IP público"`.
  - GET peers usa o usuário `monitor` (fake confere o `user`) e PUT usa `nodebeat-rw` com a senha decifrada.
- [ ] **Step 4:** Implementar até ficar verde. Linha do histórico: `Event("alteracao", "alteracao", MkRef(...), detalhe, agora, None, None)`; a rota também registra falha depois de começar a escrever (detalhe "Falhou: ...").
- [ ] **Step 5:** Suite inteira verde. Commit `feat(api): trocar peer do IPsec pelo NodeBeat`.

### Task 4: Liberar porta para IP interno (backend)

**Files:**
- Modify: `backend/nodebeat/alteracoes.py`, `backend/nodebeat/api.py`
- Test: `backend/tests/test_alteracoes.py`, `backend/tests/test_api_alteracoes.py`

**Interfaces:**
- Consumes: Tasks 1–3; `inventario.montar(raw)["nat"]` e `inventario.porta_em` para o conflito ao vivo.
- Produces:
  - `alteracoes.wan(addresses: list[dict], routes: list[dict], interfaces: set[str], ip_publico: str | None) -> str | None` (pura; `interfaces` = nomes de `/interface/print`): interface com o `ip_publico` em `/ip/address`; senão rota `dst-address=0.0.0.0/0` ativa de menor `distance`: gateway que está em `interfaces`, senão `immediate-gw` "ip%iface", senão `gateway-status` "… via iface"; o resultado precisa estar em `interfaces`.
  - `alteracoes.liberacoes(nat_rows: list[dict]) -> list[dict]` (pura): agrupa regras com `comment` começando por `nodebeat:` → `{"descricao", "protocolos": [..], "porta_externa", "ip_interno", "porta_interna", "wan", "desativada"}`, ordenado por descrição.
  - `alteracoes.liberar_porta(api, pedido: dict, ip_publico: str | None, reservadas: set[int]) -> dict`: `pedido = {"protocolo": "tcp"|"udp"|"ambos", "porta_externa": int, "ip_interno": str, "porta_interna": int, "descricao": str}`; devolve `{"wan", "regras": [ids]}`; levanta `ValueError(<mensagem para o usuário>)` em: porta reservada, conflito ao vivo (mensagem lista os usos como em `conferir_porta`), descrição repetida, WAN não reconhecida. Cada regra: `chain=dstnat action=dst-nat protocol=<p> dst-port=<ext> to-addresses=<ip> to-ports=<int> in-interface=<wan> comment=nodebeat:<descricao>`. Falha na 2ª → remove a 1ª e relança.
  - `alteracoes.remover_porta(api, descricao: str) -> int` (quantas removeu; 0 → rota 404).
  - Rotas: `GET /api/mks/{id}/portas-liberadas` → `{"liberacoes": [...], "via"}` (monitor); `POST` mesmo caminho, body `PortaIn` (pydantic: protocolo pattern `^(tcp|udp|ambos)$`, portas 1–65535, `porta_interna` opcional = externa, `ip_interno` IPv4 privado, `descricao` regex dos Global Constraints) → 201 `{"wan", "regras", "via", "avisos": [..]}`; `DELETE /api/mks/{id}/portas-liberadas?descricao=...` → 204. POST/DELETE com `nodebeat-rw`, cascata normal. `ValueError` → 422 `{"detail": msg}`.
  - Na rota POST: `ip_interno` fora das redes do inventário (excluindo `origem == "ipsec"`) → 422 "IP fora das redes da MK"; inventário sem redes ou `desatualizado` → segue com aviso "Inventário desatualizado: confira o IP". Sempre inclui o aviso "Se não abrir, confira o filtro forward da MK".

- [ ] **Step 1: Testes puros que falham:**
  - `test_wan_pelo_ip_publico`, `test_wan_rota_menor_distance`, `test_wan_v7_immediate_gw` (`"192.0.2.1%ether1"` → `ether1`), `test_wan_v6_gateway_status` (`"192.0.2.1 reachable via  ether1"` → `ether1`), `test_wan_nenhuma` → `None`.
  - `test_liberar_conflito_faixa_e_lista` (Review Focus 2): NAT `dst-port="8000-8100"` e outro `"80,8080"` → `ValueError` para 8050 e para 8080; regra desativada não conflita.
  - `test_liberar_ambos_cria_duas_com_comentario`; `test_liberar_ambos_segunda_falha_remove_primeira` (Review Focus 3); `test_liberar_porta_reservada` (8729 e uma porta de serviço); `test_liberar_descricao_repetida_case_insensitive`.
  - `test_liberacoes_agrupa_e_ignora_sem_prefixo`; `test_remover_so_mexe_com_prefixo` (regra `comment="DVR"` com mesma porta continua).
- [ ] **Step 2:** Rodar → falham. **Step 3:** Implementar até verde.
- [ ] **Step 4: Testes de rota que falham → verdes:** POST sem `senha_rw` → 409; `descricao` com aspas → 422; IP fora das redes → 422; POST ok → 201 + histórico `"Porta tcp 8080 → 192.168.88.50:80 liberada (DVR bloco B), por ana pelo túnel"`; DELETE inexistente → 404; DELETE ok → 204 + histórico `"Porta liberada (DVR bloco B) removida, por ana"`.
- [ ] **Step 5:** Suite inteira verde. Commit `feat(api): liberar porta para IP interno pelo NodeBeat`.

### Task 5: Script "permitir alterações" na Preparar MK

**Files:**
- Modify: `frontend/lib/mk_script.dart`, `frontend/lib/screens/preparar_mk.dart`
- Test: `frontend/test/mk_script_test.dart`, `frontend/test/preparar_mk_test.dart`

**Interfaces:**
- Produces: `String scriptLiberarAlteracoes({required String ipOrigem, required List<String> ipsSede, required String senha})`; `scriptDesfazer` remove também `/user remove [find where name="nodebeat-rw"]` e `/user group remove [find where name="nodebeat-rw"]` (antes das linhas do grupo `monitor`).

- [ ] **Step 1: Testes que falham** (`mk_script_test.dart`):
  - o script começa com `{`, termina com `}\n`, é só ASCII, nenhuma linha passa de 110 colunas;
  - contém `:error "Usuario monitor nao existe` (checagem antes de alterar), `policy=read,write,api`, `name=nodebeat-rw`, `address=$lista`, a senha, e `:put "  Usuario:      nodebeat-rw"`;
  - não contém `/ip service`, `/certificate` nem `/ip firewall`;
  - `scriptDesfazer` contém as duas linhas do `nodebeat-rw`.
- [ ] **Step 2:** `flutter test test/mk_script_test.dart` → falham.
- [ ] **Step 3:** Implementar no estilo do `scriptLiberarReinicio` (reusar `_lista`): grupo cria-ou-atualiza, usuário cria-ou-atualiza (`trocou` → `:put "ATENCAO: a senha do nodebeat-rw foi trocada: atualize no cadastro (Editar)."`).
- [ ] **Step 4: Cartão na Preparar MK**, entre "liberar o botão Reiniciar" e "Desfazer tudo". Título exato: **"MK já cadastrada: permitir alterações pelo NodeBeat"**. Texto exato: "Cria o usuário nodebeat-rw, que o NodeBeat usa para alterar dados da MK: liberar portas (port forward) e trocar o peer do IPsec. O usuário monitor continua só leitura. Depois de colar, preencha a senha em Editar MK → Senha de alterações. Rodar de novo troca a senha." Mostra a senha gerada, "Gerar outra senha" e "Copiar script" (chave `copiar-alteracoes`), como o cartão "Nova MK". Mesma regra de faltar `NODEBEAT_IP_ORIGEM`/`NODEBEAT_IPS_PUBLICOS_SEDE`.
  Teste em `preparar_mk_test.dart`: o título aparece e o botão copia um texto que contém `nodebeat-rw`.
- [ ] **Step 5:** `flutter test` e `flutter analyze` verdes. Commit `feat(front): script para permitir alteracoes pelo NodeBeat`.

### Task 6: Cliente da API e campo no cadastro (front)

**Files:**
- Modify: `frontend/lib/api/client.dart`, `frontend/lib/screens/mk_form.dart`
- Test: `frontend/test/mk_form_test.dart`

**Interfaces:**
- Consumes: rotas das Tasks 1, 3 e 4.
- Produces:
  - `MkDetail.temRw` (bool, de `tem_rw`); `MkInput.senhaRw` (`String?`, enviado só se não nulo) e `MkInput.removerRw` (bool, enviado só se `true`).
  - `class PeerIpsec { id, nome?, endereco, desativado, comentario, porDominio }`; `class Liberacao { descricao, protocolos, portaExterna, ipInterno, portaInterna, wan, desativada }`; `class ResultadoPeer { antigo, novo, confirmado, policiesErro, via }`; `class ResultadoLiberar { wan, via, avisos }`.
  - `ApiClient.peers(id) -> Future<({List<PeerIpsec> peers, String via})>`, `trocarPeer(id, peerId, endereco) -> Future<ResultadoPeer>`, `liberacoes(id) -> Future<List<Liberacao>>`, `liberarPorta(id, {protocolo, portaExterna, ipInterno, portaInterna, descricao}) -> Future<ResultadoLiberar>`, `removerLiberacao(id, descricao) -> Future<void>`. `peerId` e `descricao` passam por `Uri.encodeComponent`.

- [ ] **Step 1: Testes que falham** (`mk_form_test.dart`): na edição, campo "Senha de alterações (nodebeat-rw)" vazio → PUT sem `senha_rw`; preenchido → PUT com `senha_rw`; "Remover senha de alterações" (só aparece quando `tem_rw`) → PUT com `remover_rw: true`.
- [ ] **Step 2:** Rodar → falham. **Step 3:** Implementar (campo secreto com hint "deixe vazio para manter", como a senha da API; `'senha_rw'` entra no conjunto `known` de erros por campo).
- [ ] **Step 4:** `flutter test` e `flutter analyze` verdes. Commit `feat(front): senha de alteracoes no cadastro e cliente da API`.

### Task 7: Cartões "IPsec" e "Portas liberadas" no detalhe da MK

**Files:**
- Create: `frontend/lib/widgets/alteracoes.dart`
- Modify: `frontend/lib/screens/mk_detail.dart` (inserir os cartões depois de `PortasCard`; rótulo `'alteracao': 'Alteração'` em `_tipos` e `'alteracao': ''` em `_eventos`)
- Test: `frontend/test/alteracoes_test.dart`

**Interfaces:**
- Consumes: Task 6.
- Produces: `IpsecCard({required ApiClient api, required String id, required bool temRw, required List<String> ipsSede})`, que o `mk_detail` só monta quando `!mk.semIpsec`; `PortasLiberadasCard({required ApiClient api, required String id, required bool temRw})`. `ipsSede` vem de `api.prepararMk()` (carregar no detalhe uma vez).

- [ ] **Step 1: Testes que falham** (`MockClient`, padrão do `mk_reiniciar_test.dart`):
  - sem `temRw`: os dois cartões mostram o texto "Para alterar esta MK pelo NodeBeat, aplique o script 'permitir alterações' da página Preparar MK e preencha a senha no cadastro." e os botões ficam desabilitados;
  - IPsec: lista os peers; peer `por_dominio` mostra "pelo domínio: sobe sozinho pelo load balance"; "Trocar peer" → diálogo com atalhos dos `ipsSede` + campo livre, texto "Atual: X → Novo: Y", confirmar faz PUT `{"endereco": Y}`; resposta `confirmado: false` mostra "Enviado; não deu para confirmar"; sucesso mostra "pelo IP público"/"pelo túnel";
  - Portas: lista as liberações; "Liberar porta" → formulário (protocolo tcp/udp/ambos, porta externa, IP interno com sugestões de `api.ips(id)`, porta interna padrão = externa, descrição) → POST com o corpo certo; mostra a WAN e os avisos; 422 mostra o `detail`; "Remover" pede confirmação e faz DELETE com a descrição.
  - Os testes rodam em `Brightness.light` e `Brightness.dark` (como o `mk_reiniciar_test.dart`).
- [ ] **Step 2:** Rodar → falham. **Step 3:** Implementar seguindo `PortasCard`/`IpsCard` de `widgets/inventario.dart` (mixin `Carrega`, `TradeCard`, `errorText`, `sessionExpired`). Os cartões só leem a MK quando o usuário abre ("Carregar peers"/"Carregar portas"), porque a leitura vai até a MK ao vivo.
- [ ] **Step 4:** `flutter test` e `flutter analyze` verdes. Commit `feat(front): cartoes de IPsec e portas liberadas no detalhe da MK`.

### Task 8: Revisão final, deploy e teste real

- [ ] **Step 1:** Suite do backend + `flutter test` + `flutter analyze` verdes; os arquivos novos/alterados só têm IPs de exemplo (conferir contra a lista real em `docs/producao.local.md`, que é local) e nenhum domínio real.
- [ ] **Step 2:** Revisão do branch inteiro (superpowers:requesting-code-review).
- [ ] **Step 3:** Deploy no CT 119 (api + web), pelo comando registrado na memória `nodebeat-deploy-proxmox`, só com o OK do usuário.
- [ ] **Step 4 (usuário):** numa MK de teste, colar o script "permitir alterações", preencher a senha, trocar o peer para outra saída da sede e voltar; liberar e remover uma porta para um DVR. Conferir os dois temas.

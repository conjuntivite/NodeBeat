# TV pública de ataques — `https://<domínio>/tv` sem login

Data: 2026-11-26 · Status: aprovado pelo dono

## Intenção

O dono quer abrir a TV do NOC em qualquer computador, pelo domínio, sem usuário nem senha e sem restrição de rede. A TV é **só informação em tempo real**; o bloqueio de IPs atacantes será feito depois, por dentro do NodeBeat (tela logada). Como a página fica aberta na internet, nada pode vazar: senhas, sessões, usuários de acesso, IPs das MKs ou qualquer dado do painel além do que a TV mostra.

## Decisões do dono

- Aberta para a internet, sem allow-list de rede.
- Mostra os **nomes reais** das MKs e o aviso "Login de fora aceito", **sem o usuário** ("Login de fora aceito: MK · IP").

## Desenho

**Servidor (rotas novas, sem sessão):**
- `GET /api/tv/ataques?desde=<cursor>` — mesmo feed de hoje, com lista fechada de campos: `ip` (origem), `pais`, `pais_nome`, `lat`, `lon`, `mk_nome`, `via`, `n`, `sucesso`, `quando`. Nunca `usuario`, nunca IP/ID da MK.
- `GET /api/tv/tops` — do painel 24 h: `top_ips`, `top_paises`, `por_via` e `logins_externos` só com `nome`, `ip`, `pais_nome`, `via`, `quando` (sem `usuario`, sem `mk_id`).
- Nenhum visitante dispara cálculo pesado: o painel 24 h é recalculado em segundo plano a cada 60 s; `/api/tv/tops` só lê o último pronto (antes do primeiro, responde vazio).
- As rotas não leem cookie/sessão. Teste trava a lista exata de chaves das respostas.

**nginx:** `location = /tv` → redireciona para `/#/tv`; `/api/tv/` só GET/HEAD, `limit_req` por IP (excesso → 429).

**Tela:** rota `#/tv` com cliente sem login (só `/api/tv/`), sem link para o resto do sistema e sem ida ao login; tema claro/escuro salvo no navegador (localStorage). Atalho "abrir na TV" do popup de Acesso aponta para `/tv`. A rota `#/eventos/mapa` sai; o usuário da TV e o relogin de 8 h deixam de existir. O popup de Acesso continua na área logada, com o usuário.

## Abordagens

- **Rotas públicas com campos fechados (escolhida):** a página não carrega nenhuma credencial; o pior caso é ver o que a TV já mostra.
- Auto-login com token na URL (descartada): o link vira uma sessão que abre o sistema todo; vazou o link, vazou o acesso.
- Allow-list de rede no nginx (descartada pelo dono): ele quer abrir de qualquer lugar.

## Fora do escopo

Bloqueio de IPs (fase de segurança, dentro do NodeBeat); qualquer mudança no resto do sistema.

## Deixado ao implementador

Taxa do `limit_req` (sugestão: 30 r/min por IP, burst 20 — a TV faz 12/min no feed + 1/min nos tops); formato exato do cliente sem login no front.

# NodeBeat — reiniciar a MK também pelo IP público — design

Data: 2026-11-18 · Status: aguardando aprovação · Depende de: reinício pelo painel (commit 6508361) e Preparar MK

## Intenção

O botão **Reiniciar** do detalhe da MK só funciona com o IPsec no ar, porque fala com a API-SSL (8729) pelo `ip_tunel`. O caso em que reiniciar mais ajuda é justamente o túnel travado com a internet da MK funcionando. O usuário quer que o reinício também chegue pelo **IP público** da MK.

## Objetivo

O botão continua igual (decisão do usuário: **automático**). O NodeBeat tenta pelo túnel e, se não conseguir **conectar**, tenta pelo `ip_publico` do cadastro. A confirmação diz por qual caminho foi.

## Fora do escopo

- Monitoramento, inventário ou qualquer outra leitura pelo IP público. Só o reinício usa o caminho novo.
- Escolha manual do caminho no diálogo (opção B, descartada pelo usuário).

## Anti-objetivos

- Abrir a 8729 para a internet. Ela abre só para os IPs públicos da sede (`NODEBEAT_IPS_PUBLICOS_SEDE`, a mesma lista `nodebeat-sede` que já libera o ping).
- Cair no IP público quando o problema não é de rede: senha recusada, certificado diferente ou falta de permissão de reboot. Nesses casos o erro do túnel é a resposta, e tentar de novo por outro caminho só esconderia o problema.
- Mexer na senha do `monitor` nas MKs que já estão em produção.

## Abordagens

- **A — Automático: túnel e, se falhar a conexão, IP público (escolhida pelo usuário).** O botão fica igual, e o operador não precisa saber o estado do túnel.
- **B — Escolha no diálogo.** Dá mais controle, mas é um passo a mais na hora da pressa. Descartada pelo usuário.

## Como fica

### Na MK (três travas passam a aceitar também a sede, só ela)

1. **Firewall:** regra nova `chain=input protocol=tcp dst-port=8729 src-address-list=nodebeat-sede action=accept comment="monitor-api-wan"`, colocada antes da `monitor-icmp` (mesmo critério de posição da `monitor-api`). A regra `monitor-api` (só IPsec) continua como está.
2. **Serviço api-ssl:** `address`/`available-from` passa de `<ipOrigem>/32` para `<ipOrigem>/32,<ipSede1>/32,...`. Na v7 ≥ 7.24 vai `available-from`, via `[:parse (...)]`, como o Preparar já faz.
3. **Usuário `monitor`:** `address` recebe a mesma lista. A senha não muda.

Isso entra:
- **no script completo do Preparar MK**, para as MKs novas;
- **num script curto "Liberar reinício pelo IP público"**, para as MKs já cadastradas. Ele fica na página Preparar MK, ao lado do "Liberar reinício" que já existe, e usa o `ip_origem` e os `ips_publicos_sede` de `/api/preparar-mk`. Ele não depende da MK. Mexe só nas três travas acima, é idempotente (remove a regra pelo comentário e recria) e tem linhas de até 110 colunas. Detecta a versão para escolher entre `address` e `available-from`, como o Preparar faz;
- **no Desfazer**, que passa a remover também a regra `monitor-api-wan`.

### No NodeBeat

- `routeros._erro` passa a marcar as falhas de rede (timeout, conexão recusada) com uma subclasse `SemConexao(RouterOsError)`. TLS, login e permissão continuam como `RouterOsError` comum.
- **`POST /api/mks/{id}/reiniciar`:**
  - tenta `reboot(ip_tunel)`;
  - em `SemConexao`, se a MK tem `ip_publico`, tenta `reboot(ip_publico)` com o mesmo usuário, senha e certificado fixado. O certificado é o mesmo, então o pin vale;
  - responde `{"via": "tunel" | "publico"}`;
  - se os dois falharem, devolve 502 com os dois motivos: `"Túnel: <x>. IP público: <y>"`.
- **Painel:** o aviso de sucesso vira "Reinício enviado pelo túnel" ou "Reinício enviado pelo IP público". O erro mostra o texto da API, como hoje.
- **Timeout:** 5 s por tentativa, igual ao atual. No pior caso o botão espera uns 10 s.

### Caminho de rede (conferido em 2026-11-18)

- O CT sai para a internet pela sede (rota padrão pela eth0), com o IP público primário. Ele está na lista `nodebeat-sede`, e a lista inclui os 3 IPs por causa do load balance.
- O destino é o IP público da MK, fora das policies IPsec, então vai pela internet.
- O ping do worker para o `ip_publico` já usa esse caminho.

## Riscos aceitos

- A 8729 fica visível na WAN para 3 IPs. A proteção é a lista de IPs em três camadas, TLS com certificado fixado, senha forte e um usuário sem `write`.
- Se a internet da MK estiver fora, o reinício não chega por nenhum dos dois caminhos.

## Testes

- Backend:
  - túnel ok → `via=tunel` e nenhuma tentativa no público;
  - túnel com `SemConexao` → tenta o público → `via=publico`;
  - túnel com login recusado ou certificado diferente → 502 sem tentar o público;
  - os dois sem conexão → 502 com os dois motivos;
  - MK sem `ip_publico` → só o túnel.
- Scripts:
  - o curto contém a regra `monitor-api-wan` com `src-address-list=nodebeat-sede`, as listas de IPs no serviço e no usuário, e não contém `password`;
  - ASCII;
  - linhas de até 110 colunas;
  - o Desfazer remove `monitor-api-wan`.
- Painel: o aviso mostra o caminho.
- **Real:** antes de soltar para todas, aplicar o script curto numa MK de teste e conferir do CT `openssl s_client -connect <ip_publico>:8729`. Depois, reiniciar uma MK de teste com o túnel desligado, com o usuário escolhendo a MK e o momento.

## Para o construtor

Nomes internos, texto exato das mensagens e o formato do teste de fallback (mock de `routeros.reboot`).

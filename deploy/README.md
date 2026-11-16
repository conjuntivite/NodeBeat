# Implantação do NodeBeat

Quatro pastas importam: `deploy/` (compose, nginx, `.env`, certificado), `backend/`, `frontend/` e o script RouterOS.
Só o nginx (`web`) escuta fora; Mongo, Redis, API e worker ficam na rede interna do compose.

## 1. VM (Proxmox)

1. Crie uma VM Linux com Docker e o plugin Compose, alcançável pelo SonicWall (IP `<IP_DA_VM>`).
2. Clone o repositório na VM.
3. `cp deploy/.env.example deploy/.env` e preencha tudo (veja os comentários no arquivo). As URLs do Mongo e do Redis são montadas no `compose.yml` a partir de `MONGO_PASSWORD` e `REDIS_PASSWORD`; gere essas senhas com `openssl rand -hex 32`. `NODEBEAT_BIND_IP` = `<IP_DA_VM>`.
   `MONGO_PASSWORD` só vale na primeira inicialização do volume do Mongo (`MONGO_INITDB_*`): trocá-la depois quebra a autenticação, a menos que o usuário seja alterado dentro do Mongo.
   A rede do compose usa a sub-rede fixa `172.30.0.0/24` (em `compose.yml`, junto com `--forwarded-allow-ips` da api); troque se colidir com a rede da VM.
   **Trocar a `NODEBEAT_SECRET_KEY` depois inutiliza as senhas de MK já guardadas** (é preciso recadastrá-las).
4. Certificado autoassinado:
   ```sh
   mkdir -p deploy/certs
   openssl req -x509 -newkey rsa:2048 -days 825 -nodes -subj "/CN=nodebeat" \
     -addext "subjectAltName=IP:<IP_DA_VM>" \
     -keyout deploy/certs/nodebeat.key -out deploy/certs/nodebeat.crt
   ```
   `deploy/certs/` é ignorado pelo git: nunca commite a chave.
5. Suba: `docker compose -f deploy/compose.yml --env-file deploy/.env up -d --build`
   (o build do frontend clona o Flutter 3.50.0 do GitHub; o primeiro build leva ~10 min).
6. Primeiro usuário:
   `docker compose -f deploy/compose.yml --env-file deploy/.env exec api python -m nodebeat.cli create-user admin`
7. Abra `https://<IP_DA_VM>` (aceite o certificado autoassinado) e entre.

### Em CT LXC do Proxmox (em vez de VM)

Funciona num CT Debian 12 sem privilégios, com estes ajustes:

- `features: nesting=1,keyctl=1` e `lxc.apparmor.profile: unconfined` no `/etc/pve/lxc/<ID>.conf`; sem o AppArmor liberado o runc não inicia containers.
- **4 GB de RAM**: com 2 GB o build do Flutter web fica sem memória.
- **Faixa do Docker**: se alguma rede de MK cair em `172.17.0.0/16` (padrão do `docker0`), troque em `/etc/docker/daemon.json`, por exemplo `{"bip":"10.250.0.1/24","default-address-pools":[{"base":"10.251.0.0/16","size":24}]}`.
- **Origem coberta pelo IPsec**: se os túneis das MKs só aceitam uma rede da sede (ex.: `<REDE_SEDE_IPSEC>`), dê ao CT uma 2ª placa nessa rede (`<IP_CT_IPSEC>`) e um serviço no boot com rotas para as redes das MKs saindo com essa origem, mais SNAT dos containers (o MASQUERADE do Docker usaria o IP da outra placa):
  ```sh
  for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    ip route replace $n via <GATEWAY_SEDE> dev eth0 src <IP_CT_IPSEC>
    iptables -t nat -C POSTROUTING -o eth0 -d $n -j SNAT --to-source <IP_CT_IPSEC> 2>/dev/null \
      || iptables -t nat -I POSTROUTING 1 -o eth0 -d $n -j SNAT --to-source <IP_CT_IPSEC>
  done
  # antes das regras acima: tráfego para a própria LAN do CT não leva SNAT
  iptables -t nat -C POSTROUTING -o eth0 -d <REDE_LAN_CT> -j RETURN 2>/dev/null \
    || iptables -t nat -I POSTROUTING 1 -o eth0 -d <REDE_LAN_CT> -j RETURN
  ```
- O worker pinga com `net.ipv4.ping_group_range` (já no `compose.yml`), que funciona no LXC; `NET_RAW` não chega ao usuário não-root do container ali.

## 2. Cada MikroTik

Aplique `deploy/routeros-monitor-user.rsc` (instruções e placeholders no topo do arquivo), com `<IP_VM>` = o IP de origem com que a VM chega na MK (o do túnel). Cadastre a MK no painel.

- **IP do túnel** no cadastro = o IP da LAN da MK dentro da rede do IPsec (`/ip ipsec policy print` → `SRC-ADDRESS`; `/ip address print` → o endereço da MK nessa rede, em geral o da `bridge`).
- **IP público** = o IP fixo da WAN (para distinguir "VPN caiu" de "Offline").
- No RouterOS ≥ 7.24 o parâmetro `address` do `/ip service` virou `available-from` (o antigo ainda funciona, com aviso).

## 3. SonicWall

Regra de saída: origem = `<IP_DA_VM>`, destino = redes dos condomínios, serviços TCP 8729 + ICMP. Nada mais.

## 4. Checklist de verificação (manual)

- [ ] `docker compose ... ps`: os 5 serviços `running`.
- [ ] Login em `https://<IP_DA_VM>` funciona; `http://` redireciona para `https://`.
- [ ] Uma MK real cadastrada aparece "No ar" com CPU, memória e versão em até 60 s.
- [ ] Com `NODEBEAT_WEBHOOK_URL` apontando para um endpoint de teste: bloqueie a 8729 da VM no SonicWall; em ~2,5 min chega `queda` (`erro_acesso` ou `vpn_caiu`); desbloqueie; ~1 min depois o painel registra o retorno no histórico da MK (o webhook só envia a `queda`, que abre o ticket).
- [ ] `ss -tlnp` na VM: só 80/443 no `<IP_DA_VM>` (mais SSH e afins do próprio host).
- [ ] Os dois temas e o carregamento do app sem erros de CSP no console do navegador.

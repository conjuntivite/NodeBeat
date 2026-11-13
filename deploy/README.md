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
   (o build do frontend baixa a imagem `ghcr.io/cirruslabs/flutter:3.50.0`; se a tag não existir, ajuste em `frontend/Dockerfile`).
6. Primeiro usuário:
   `docker compose -f deploy/compose.yml --env-file deploy/.env exec api python -m nodebeat.cli create-user admin`
7. Abra `https://<IP_DA_VM>` (aceite o certificado autoassinado) e entre.

## 2. Cada MikroTik

Aplique `deploy/routeros-monitor-user.rsc` (instruções e placeholders no topo do arquivo), com `<IP_VM>` = o IP de origem com que a VM chega na MK (o do túnel). Cadastre a MK no painel.

## 3. SonicWall

Regra de saída: origem = `<IP_DA_VM>`, destino = redes dos condomínios, serviços TCP 8729 + ICMP. Nada mais.

## 4. Checklist de verificação (manual)

- [ ] `docker compose ... ps`: os 5 serviços `running`.
- [ ] Login em `https://<IP_DA_VM>` funciona; `http://` redireciona para `https://`.
- [ ] Uma MK real cadastrada aparece "No ar" com CPU, memória e versão em até 60 s.
- [ ] Com `NODEBEAT_WEBHOOK_URL` apontando para um endpoint de teste: bloqueie a 8729 da VM no SonicWall; em ~2,5 min chega `queda` (`erro_acesso` ou `vpn_caiu`); desbloqueie; ~1 min depois chega `retorno`.
- [ ] `ss -tlnp` na VM: só 80/443 no `<IP_DA_VM>` (mais SSH e afins do próprio host).
- [ ] Os dois temas e o carregamento do app sem erros de CSP no console do navegador.

# Preparar MK: Winbox na 18291

Data: 2026-11-19. Mudança pequena. O usuário escolheu a opção 2: "pode seguir com a 2 por enquanto. pois precisarei acessar de fora da empresa".

## Por quê
Duas operadoras bloqueiam a 8291 (DONA IOLANDA, REAL PARK, VOGUE, provavelmente a COSMOPOLITANO). A meta é deixar todas as
MKs prontas para reiniciar pelo túnel e pelo IP fixo e para o acesso externo do usuário pelo Winbox, de qualquer lugar.
A restrição por IP da sede e o bloqueio de serviços ficam para a etapa de segurança.

## Abordagens
1. Liberar a 18291 só da sede (lista `nodebeat-sede` e túnel). Recusada por agora: o usuário precisa acessar de fora.
2. **Escolhida: liberar a 18291 de qualquer IP.** Risco aceito pelo usuário até a etapa de segurança.

## Design (só no Preparar)
Ajuste do usuário: "essa regra do acesso externo seria apenas para as novas mk's, pois as atuais já acessam pela porta 8291,
e as que nao acessavam a gente ajustou". O cartão "liberar o botão Reiniciar" não mexe no Winbox.

- Regra `chain=input protocol=tcp dst-port=18291 action=accept comment=winbox-alt`, criada desligada, levada para antes da
  primeira regra `input` não dinâmica e então ligada. Antes de criar, remove a antiga (idempotente).
- `/ip service set winbox port=18291` é **a última linha do bloco**: a sessão do Winbox cai na troca e pode interromper o
  terminal. Não mexe no `address` do serviço.
- Desfazer: remove a regra `winbox-alt`. A porta não volta para a 8291, porque nas MKs com bloqueio da operadora isso
  cortaria o acesso externo (decisão minha).
- Página: aviso, no cartão do Preparar, de que a sessão cai ao final e que depois se entra por `<ip>:18291`.

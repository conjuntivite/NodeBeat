# Preparar MK: NAT da porta alternativa e aviso de colagem

Data: 2026-11-19. Mudança pequena. Aprovada pelo usuário: "faz o 1 e 2, o 3 fica para quando tratarmos a parte de segurança".

## Por quê
- Uma operadora bloqueou a 8729, e o reinício pelo IP público precisou de NAT 18729→8729 aplicado à mão. O NodeBeat já
  tenta a 18729 (commit 0886700).
- Numa colagem, a `{` se perdeu e o bloco rodou linha por linha, com `invalid value`. A página não explicava o que fazer.

## Abordagens
1. **Escolhida: regra sempre presente.** Tanto o Preparar quanto o cartão "liberar o botão Reiniciar" criam a regra.
   Ela não atrapalha nas MKs sem bloqueio.
2. Regra só quando houver bloqueio. Descartada: o script não tem como detectar um bloqueio da operadora.
3. Winbox na 18291: fica para o projeto de segurança, por decisão do usuário.

## Design
- **Preparar** (a WAN já é conhecida): remove `comment="monitor-api-alt"` e adiciona
  `chain=dstnat in-interface=$wan protocol=tcp dst-port=18729 action=redirect to-ports=8729 comment="monitor-api-alt"`.
- **Liberar reinício** (script curto, sem WAN, linhas ≤ 80): a mesma regra, sem `in-interface`, montada com add + set.
- **Desfazer:** remove a regra `monitor-api-alt`.
- **Página:** aviso nos dois cartões: se aparecer `invalid value` ou `expected end of command`, a colagem perdeu parte
  do script (a `{` do começo); cole de novo o script inteiro, que pode ser repetido.

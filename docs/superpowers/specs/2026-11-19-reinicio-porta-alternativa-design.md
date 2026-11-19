# Reinício pelo IP público: porta alternativa 18729

Data: 2026-11-19. Mudança pequena.

## Por quê
Em uma MK, a operadora bloqueia a porta 8729 (api-ssl) na entrada. A liberação do reinício pelo IP público já foi aplicada
nela e está correta, mas a conexão não chega até a MK. O botão Reiniciar precisa alcançá-la pelo IP público mesmo assim.

## Abordagens
1. **Escolhida: segunda tentativa automática.** Quando o IP público não conecta na 8729 (falha de rede), o NodeBeat
   tenta a 18729. Na MK bloqueada, uma regra de NAT só na WAN redireciona a 18729 para a 8729. Não muda o cadastro nem o
   painel e serve para qualquer MK futura com o mesmo bloqueio. Custo: quando a MK está realmente fora, o erro demora uns
   5 s a mais.
2. Campo "porta da API pelo IP público" no cadastro. Fica explícito, mas mexe em cadastro, tela e testes, e alguém
   precisa lembrar de preencher.
3. Trocar a porta da api-ssl na MK. Descartada: o monitoramento pelo túnel usa a 8729.

## Design
- `routeros.reboot` ganha o parâmetro `porta` (padrão 8729), que é repassado ao `librouteros.connect`.
- Em `POST /api/mks/{id}/reiniciar`, o caminho pelo IP público tenta a 8729. **Só em `SemConexao`** ele tenta a 18729.
  Login, certificado e falta de permissão continuam sem nova tentativa.
- Quando tudo falha, a mensagem mantém o formato atual (`Túnel: … IP público: …`) e mostra o erro da última tentativa.
- O caminho usado aparece como antes: "pelo IP público", sem citar a porta.
- O túnel e o worker não mudam: continuam só na 8729.

## Na MK (manual, aplicado pelo usuário)
```
/ip firewall nat add chain=dstnat in-interface=<WAN> protocol=tcp dst-port=18729 action=redirect to-ports=8729 comment=monitor-api-alt
```
A api-ssl, o usuário `monitor` e a regra `monitor-api-wan` já aceitam a sede. Depois do redirect, o filtro vê a porta 8729.

## Fora do escopo
- Gerar essa regra pela página Preparar MK. Ela só entra se o bloqueio aparecer em mais MKs.
- Mostrar a porta usada no aviso.

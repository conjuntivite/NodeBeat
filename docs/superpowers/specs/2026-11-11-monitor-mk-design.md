# NodeBeat — monitor de MKs — design (fase 1)

Data: 2026-11-11 · Status: aprovado · Nome do sistema: **NodeBeat** (batimento dos equipamentos; renomeado em 2026-11-12)

## Intenção

Hoje a empresa só descobre que a MK (MikroTik) ou a VPN de um condomínio caiu quando um cliente reclama que o app não funciona, ou quando alguém por acaso abre o sistema ONE PORTARIA. O objetivo é que **o responsável e a equipe de TI fiquem sabendo antes do cliente**, com aviso automático e um painel que mostre o estado de todas as MKs.

## Contexto da rede

- ~23 MKs, uma por condomínio, e o número tende a crescer.
- Todas fecham **IPsec** com o firewall **SonicWall** da sede.
- Cada condomínio tem **IP público fixo**.
- O sistema roda numa **VM ou container Linux no Proxmox**, na rede da sede atrás do SonicWall. **Não** roda no servidor Windows <IP_SERVIDOR_WINDOWS>.

## Objetivos

1. Detectar MK fora, VPN caída, CPU ou memória altas e interface vigiada caída.
2. Enviar o aviso de queda e o de retorno para um webhook (sistema próprio, aceita JSON).
3. Ter um painel web interno com o estado de todas as MKs, o histórico de quedas e o cadastro.
4. Não abrir nenhuma brecha nova de segurança.

## Fora do escopo (fase 1)

- Monitorar equipamentos IP (câmeras, controladoras etc.). Isso é a fase 2, com spec própria. O design não pode impedi-la, mas também não deve prepará-la além do óbvio.
- Acesso ao painel de fora da rede interna.
- Alterar configuração das MKs pelo sistema. O sistema **só lê**.
- Integração com o ONE PORTARIA.
- Gráficos de série histórica de CPU e memória. O painel mostra o valor atual.

## Anti-objetivos (seria falha mesmo funcionando)

- Abrir porta para a internet, seja no SonicWall, na VM ou nas MKs, ou dar ao monitor um usuário com permissão de escrita nas MKs.
- Guardar senha de MK em texto puro.
- Alarme falso por queda de poucos segundos. A equipe para de confiar no aviso.
- Ficar sem aviso de retorno: a equipe precisa saber quando normalizou.

## Stack (decisão do usuário)

- **Back-end:** Python.
- **Front-end:** Flutter (web).
- **Banco:** MongoDB, com MKs, interfaces vigiadas e usuários do painel.
- **Redis:** histórico/log de eventos (quedas e retornos), com **persistência AOF ligada**.
- **Visual:** design system **Trade UI** (`C:/Users/User/design-systems/trade-ui/`), com os tokens convertidos para `ThemeData` do Flutter a partir de `tokens/tokens.json` e os temas claro e escuro. Copiar os tokens e o logo para dentro do projeto, não importar da pasta global.

Escolha do designer: Python com FastAPI na API e `librouteros` para a API do RouterOS. Tudo sobe com `docker compose` na VM.

## Como cada MK é verificada

A cada **30 s** (escolha do designer), para cada MK cadastrada:

1. Conecta na **API do RouterOS com TLS (porta 8729)** pelo **IP da MK dentro do túnel**, com o usuário só de leitura.
   - Se der certo, a MK está no ar. Coleta: `cpu-load`, memória (`1 − free-memory/total-memory`), `uptime` e o estado `running` de cada interface vigiada.
2. Se a API falhar, o sistema faz dois testes de ping:
   - **Ping no IP do túnel** responde → estado `erro_acesso`. A MK está alcançável, mas a API ou a credencial falhou.
   - Não responde → **ping no IP público fixo**:
     - responde → `vpn_caiu`
     - não responde → `offline` (caiu o link ou a MK)

Estados de uma MK: `no_ar`, `vpn_caiu`, `offline`, `erro_acesso`. Alertas paralelos enquanto ela está `no_ar`: `cpu_alta` (> 80%), `memoria_alta` (> 80%) e `interface_caida` (por interface vigiada).

**Pré-requisito de rede:** o ping no IP público sai pela internet, não pelo túnel. Cada MK precisa aceitar ICMP no WAN **apenas** do IP público da sede.

### Versões do RouterOS e TLS

- O parque tem **RouterOS v6 e v7 misturados** (decisão/fato do usuário). O sistema precisa funcionar com os dois sem nenhum campo de versão no cadastro: ele detecta e lê `/system/resource` `version` e registra no painel.
- Versão mínima suportada: **v6.43**, que trouxe o login em texto puro dentro do TLS (escolha do designer). Uma MK abaixo disso aparece como `erro_acesso` com o detalhe "RouterOS anterior a 6.43, atualizar".
- Cada MK recebe um **certificado autoassinado** para o `api-ssl`, criado pelo script de implantação. No primeiro contato depois do cadastro, o monitor grava a **impressão digital (SHA-256)** do certificado e, a partir daí, recusa conexão se ela mudar (estado `erro_acesso`, detalhe "certificado mudou"). No painel há um botão "aceitar novo certificado" para quando a troca for legítima (escolha do designer).
- Risco técnico a validar logo no início: o `api-ssl` do v6 com certificado + o `ssl` do Python moderno (versão de TLS e cifras). Fazer um teste rápido contra uma MK v6 e uma v7 reais antes de construir o resto.

### Referência: falha na sede

A cada ciclo, antes de avaliar as MKs, o monitor testa a referência **`<HOST_REFERENCIA>`** (decisão do usuário), resolvendo o DNS e fazendo um HTTPS `HEAD` com timeout curto.

- Se a referência falhar, o problema é na sede: internet, SonicWall ou rede da VM. O sistema abre **um único** evento `falha_sede` e **congela** a avaliação das MKs. Nenhuma MK abre ou fecha evento enquanto isso durar.
- A regra dos 2 minutos vale também aqui.
- Como o webhook fica **na internet** (via Cloudflare), um aviso de `falha_sede` não chega enquanto a sede está sem internet. Os eventos não entregues ficam numa **fila persistida no Redis** e são enviados em ordem assim que a conexão volta: primeiro a `queda` de `falha_sede`, depois o `retorno` dela, com a duração.
- Quando a referência volta, as MKs são reavaliadas do zero, e a regra dos 2 minutos começa a contar de novo.

## Regras de alerta

- Uma condição só vira alerta quando persiste por **2 minutos seguidos**. Vale para queda, VPN, `erro_acesso`, CPU, memória e interface.
- Ao virar alerta, o sistema envia **um** evento `queda`. Quando a condição some e fica **1 minuto estável**, envia **um** evento `retorno` com a duração (escolha do designer, para evitar rajada com link oscilando).
- Enquanto o alerta continua, nada é reenviado.
- `inicio` = momento da **primeira falha detectada**, não do disparo do alerta. `duracao_s` = `fim − inicio`.
- **Mudança entre estados de queda** (ex.: `vpn_caiu` → `offline`): **não** envia `retorno`, porque a MK continua fora. O evento anterior é encerrado só no histórico, e na hora sai uma nova `queda` com o tipo novo, sem esperar outros 2 minutos (escolha do designer). O `retorno` final leva o `inicio` da primeira queda do incidente.
- **Quando a MK cai**, os alertas paralelos abertos (`cpu_alta`, `memoria_alta`, `interface_caida`) são encerrados em silêncio, sem `retorno` (escolha do designer).

**Webhook** (formato escolhido pelo designer; o sistema de destino aceita JSON livre). Fica **na internet, via Cloudflare** (fato do usuário). A URL vem de variável de ambiente. Se a variável opcional `WEBHOOK_TOKEN` estiver definida, ela vai no cabeçalho `Authorization: Bearer <token>` (escolha do designer). A conexão de saída é só HTTPS e não abre nada para dentro.

```json
{
  "evento": "queda",
  "tipo": "vpn_caiu",
  "mk": { "id": "…", "nome": "Cond. Alfa" },
  "detalhe": "Túnel sem resposta; IP público responde",
  "inicio": "2026-11-11T14:02:00-03:00",
  "fim": null,
  "duracao_s": null
}
```

`evento` ∈ `queda | retorno`. `tipo` ∈ `offline | vpn_caiu | erro_acesso | cpu_alta | memoria_alta | interface_caida | falha_sede`. Em `falha_sede`, `mk` é `null`. No retorno, `fim` e `duracao_s` vêm preenchidos. Para `interface_caida`, o `detalhe` traz o nome da interface.

Entrega: todo evento entra numa **fila persistida no Redis** e é enviado em ordem. Se o POST falhar, o evento continua na fila e o sistema tenta de novo com espera crescente, até 5 min entre tentativas, sem descartar. A fila nunca trava a verificação das MKs. No painel, aparece o aviso "N eventos aguardando envio" quando a fila não estiver vazia.

## Histórico

- Cada evento (queda e retorno) fica no **Redis** por **90 dias** (escolha do designer) e depois é apagado.
- No painel, o histórico pode ser consultado por MK.

## Painel

Só na rede interna. Layout **B** (escolhido pelo usuário, porque o número de MKs vai crescer):

- **Topo:** três números: *No ar*, *Com alerta*, *Fora*.
- **Tabela:** uma linha por MK, com condomínio, status (com o tempo desde a mudança), CPU, memória, uptime e interfaces vigiadas de pé ("3/3"). Ordenável, com problemas no topo por padrão. Atualiza sozinha.
- **Detalhe da MK:** métricas atuais, estado de cada interface vigiada e histórico de eventos.
- **Cadastro (formulário):** nome do condomínio, IP da MK no túnel, IP público fixo, usuário e senha da API. Depois de salvar, o sistema lê as interfaces da MK e o usuário marca quais vigiar. Dá para editar e remover.
- **Usuários:** login individual. Todos têm a mesma permissão (escolha do designer). O primeiro usuário é criado por comando na VM.
- Números com `tabular-nums`, status com cores semânticas (`positive`, `warning`, `negative`). Temas claro e escuro.

## Segurança

- **Nenhuma porta nova para a internet.** O monitor acessa as MKs pelos túneis IPsec existentes. As únicas saídas para a internet são o HTTPS para o webhook e a referência, e o ICMP para os IPs públicos dos condomínios.
- Conexão com as MKs só por TLS, com o certificado fixado pela impressão digital (ver "Versões do RouterOS e TLS").
- No **SonicWall**, só o IP da VM do monitor é liberado para as redes dos condomínios, e só na porta 8729/TCP e para ICMP.
- Em cada **MK**: um usuário exclusivo do grupo `read` (sem `write`, `policy`, `ssh`, `ftp`, `winbox` etc.) com `address=` restrito ao IP da VM. O serviço `api-ssl` também fica restrito ao IP da VM.
- **Senhas das MKs** criptografadas no MongoDB (criptografia simétrica autenticada), com a chave numa variável de ambiente da VM, fora do banco. A senha nunca volta para o front.
- **Senhas do painel** guardadas como hash forte (bcrypt/argon2). Sessão expira.
- Painel e API escutam só na interface interna da VM. MongoDB e Redis não expõem porta fora da rede do compose e exigem senha.
- O front nunca fala direto com as MKs. Só o back fala.

## Fica a cargo de quem construir

- Organização do código, framework de agendamento das verificações e como API e verificador convivem (um processo ou dois).
- Mecanismo de sessão do painel e estrutura exata das coleções e chaves no Redis.
- Como o Flutter web é servido (nginx ou pela própria API).
- Documentação curta de implantação: compose, variáveis de ambiente, script RouterOS de exemplo para criar o usuário só de leitura e a regra de ICMP, e regras do SonicWall.

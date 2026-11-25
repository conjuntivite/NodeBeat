# Painel de usuários com tema salvo — design

Aprovado pelo dono em 2026-11-25 ("sim, aprovado, pode seguir").

## Intenção

Hoje só dá para criar usuário pela linha de comando, dentro do servidor, e o tema (claro/escuro) se perde ao recarregar a página. O dono quer uma tela de usuários e que cada pessoa tenha o seu tema guardado.

Regra do dono: **só o admin cadastra usuários; o resto só troca a própria senha.**

## Objetivos

1. Níveis de acesso: admin e comum.
2. Tela **Usuários** (só admin):
   - listar;
   - criar com senha inicial;
   - redefinir a senha de alguém;
   - promover ou rebaixar;
   - remover.
3. **Minha conta** (todos): trocar a própria senha, informando a atual.
4. O tema escolhido fica no cadastro do usuário, e o NodeBeat abre nele ao entrar. Quem nunca escolheu entra no claro.

## Não objetivos

Recuperação de senha por e-mail, SSO, log de auditoria e permissões por MK.

## Abordagem

Só uma sensata: estender a coleção `users` e o login atual (argon2 + sessão em Redis `sess:<token>`). Um serviço de login à parte (SSO/OAuth) seria desproporcional para o time.

## Design

- **Dados:** `users` ganha:
  - `admin: bool`;
  - `tema: "claro" | "escuro" | null`.
- **Migração:**
  - sem script: usuário sem o campo `admin` conta como admin (hoje todos foram criados pela CLI), e todo usuário novo grava `admin: false` (decisão do builder, mesmo efeito);
  - a CLI `create-user` ganha `--admin`.
- **Senha:** mínimo de **12** caracteres, a mesma regra da CLI (`cli.MIN_SENHA`), também na tela.
- **Sessões:**
  - o login registra o token também num conjunto Redis `sess_u:<usuario>`;
  - remover um usuário ou ter a senha redefinida pelo admin apaga todas as sessões dele;
  - trocar a própria senha mantém só a sessão atual.
- **API:**
  - Qualquer usuário logado:
    - `GET /api/auth/me` devolve `{usuario, admin, tema}`;
    - `PUT /api/auth/tema` recebe `{tema}`;
    - `PUT /api/auth/senha` recebe `{atual, nova}`. Se a senha atual estiver errada, devolve 400 com "Senha atual incorreta".
  - Só admin (os outros recebem 403):
    - `GET /api/usuarios` devolve `[{usuario, admin, criado_em}]`, nunca o hash;
    - `POST /api/usuarios` recebe `{usuario, senha, admin}`. Usuário repetido devolve 409;
    - `PUT /api/usuarios/{u}` recebe `{senha?, admin?}`;
    - `DELETE /api/usuarios/{u}`.
  - Travas (respondem 409):
    - ninguém se remove nem se rebaixa;
    - o último admin não pode ser removido nem rebaixado.
  - O nome do usuário é normalizado como no login: `strip().lower()`.
- **Telas** (visual Inviolável/pink, dois temas):
  - **Usuários:** item na barra lateral, só para admin. Tabela com Usuário, Admin (Selo) e Criado em, mais ações por linha: redefinir senha, promover/rebaixar e remover, este com confirmação. O botão "Novo usuário" abre um diálogo.
  - **Minha conta:** ícone no rodapé da barra lateral, ao lado do Sair, em todas as telas. Abre um diálogo com senha atual, nova e confirmação.
  - **Tema:** o botão de tema salva via `PUT /api/auth/tema`. Depois do login, ou ao recarregar já logado, o app lê `me` e aplica o tema.

## Restrições

- TDD.
- Nenhuma senha ou hash em log, erro ou resposta.
- `flutter analyze` limpo.
- Usuários de teste fictícios.

## Deixado para o builder

- Textos exatos.
- Onde guardar o usuário logado no front (um `ValueNotifier` global, como o `themeMode`).

import 'package:material_ui/material_ui.dart';

import 'api/client.dart';
import 'theme/theme.dart';

/// Quem está logado (null = ainda não carregado ou deslogado).
final usuarioAtual = ValueNotifier<Eu?>(null);

/// Cliente da sessão, usado pelo botão de tema para gravar a escolha.
ApiClient? apiSessao;

/// Lê /auth/me, guarda o usuário e aplica o tema salvo. Qualquer erro é ignorado.
Future<void> carregarSessao(ApiClient api) async {
  apiSessao = api;
  try {
    final eu = await api.me();
    usuarioAtual.value = eu;
    themeMode.value = eu.tema == 'escuro' ? ThemeMode.dark : ThemeMode.light;
  } catch (_) {}
}

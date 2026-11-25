import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/shell.dart';

const _minSenha = 12;

String? _validarSenha(String s) => s.length < _minSenha ? 'A senha precisa ter no mínimo $_minSenha caracteres' : null;

String _data(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year}';
}

/// Diálogo de "Minha conta": troca a própria senha. Mostra "Senha alterada" no sucesso.
Future<void> abrirMinhaConta(BuildContext context, ApiClient api) async {
  final msg = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _FormDialog(
      titulo: 'Minha conta',
      campos: const ['Senha atual', 'Nova senha', 'Confirmar'],
      validar: (v) => _validarSenha(v[1]) ?? (v[1] != v[2] ? 'As senhas não conferem' : null),
      enviar: (v, _) => api.trocarSenha(v[0], v[1]),
    ),
  );
  if (ok == true) msg.showSnackBar(const SnackBar(content: Text('Senha alterada')));
}

class UsuariosScreen extends StatefulWidget {
  const UsuariosScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<UsuariosScreen> createState() => _UsuariosScreenState();
}

class _UsuariosScreenState extends State<UsuariosScreen> {
  List<Usuario>? _lista;
  String? _erro; // falha ao listar
  String? _aviso; // falha de uma ação

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await widget.api.usuarios();
      if (mounted) setState(() => _lista = l);
    } catch (e) {
      if (mounted && !sessionExpired(context, e)) setState(() => _erro = errorText(e));
    }
  }

  Future<void> _acao(Future<void> Function() f) async {
    try {
      await f();
      _aviso = null;
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      _aviso = errorText(e);
    }
    await _load();
  }

  Future<void> _novo() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _FormDialog(
        titulo: 'Novo usuário',
        campos: const ['Usuário', 'Senha'],
        comAdmin: true,
        validar: (v) => v[0].trim().isEmpty ? 'Informe o usuário' : _validarSenha(v[1]),
        enviar: (v, admin) => widget.api.criarUsuario(v[0].trim().toLowerCase(), v[1], admin: admin),
      ),
    );
    _aviso = null;
    await _load();
  }

  Future<void> _redefinir(Usuario u) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _FormDialog(
        titulo: 'Redefinir senha de ${u.usuario}',
        campos: const ['Nova senha'],
        validar: (v) => _validarSenha(v[0]),
        enviar: (v, _) => widget.api.atualizarUsuario(u.usuario, senha: v[0]),
      ),
    );
  }

  Future<void> _remover(Usuario u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remover ${u.usuario}?'),
        content: const Text('O usuário perde o acesso e as sessões abertas são encerradas.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Remover')),
        ],
      ),
    );
    if (ok == true) await _acao(() => widget.api.removerUsuario(u.usuario));
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final lista = _lista;
    return AppShell(
      ativo: 'usuarios',
      titulo: 'Usuários',
      acoes: [FilledButton(onPressed: _novo, child: const Text('Novo usuário'))],
      body: lista == null
          ? Center(
              child: _erro == null
                  ? const CircularProgressIndicator()
                  : Text(_erro!, style: TradeType.bodyMd.copyWith(color: t.negative)))
          : ListView(padding: margemPagina(context), children: [
              if (_aviso != null) Aviso(_aviso!, cor: t.negative),
              TradeCard(
                child: Column(children: [
                  for (var i = 0; i < lista.length; i++) ...[
                    if (i > 0) Divider(height: t.space4, color: t.borderSubtle),
                    _linha(t, lista[i]),
                  ],
                ]),
              ),
            ]),
    );
  }

  Widget _linha(TradeTokens t, Usuario u) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: t.space2, runSpacing: t.space1, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(u.usuario, style: TradeType.bodyMd.copyWith(color: t.fgPrimary, fontWeight: FontWeight.w500)),
              if (u.admin) Selo('Admin', t.info),
            ]),
            Text(_data(u.criadoEm), style: TradeType.label.copyWith(color: t.fgSecondary)),
          ]),
        ),
        IconButton(
          tooltip: 'Redefinir senha de ${u.usuario}',
          icon: const Icon(Icons.key_outlined, size: 20),
          onPressed: () => _redefinir(u),
        ),
        IconButton(
          tooltip: u.admin ? 'Remover admin de ${u.usuario}' : 'Tornar admin: ${u.usuario}',
          icon: Icon(u.admin ? Icons.shield : Icons.shield_outlined, size: 20),
          onPressed: () => _acao(() => widget.api.atualizarUsuario(u.usuario, admin: !u.admin)),
        ),
        IconButton(
          tooltip: 'Remover usuário ${u.usuario}',
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: () => _remover(u),
        ),
      ]);
}

/// Diálogo de campos de texto (todos ocultos, menos "Usuário"); pop(true) quando [enviar] dá certo.
class _FormDialog extends StatefulWidget {
  const _FormDialog({
    required this.titulo,
    required this.campos,
    required this.validar,
    required this.enviar,
    this.comAdmin = false,
  });
  final String titulo;
  final List<String> campos;
  final bool comAdmin;
  final String? Function(List<String> valores) validar; // mensagem de erro local, ou null
  final Future<void> Function(List<String> valores, bool admin) enviar;

  @override
  State<_FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<_FormDialog> {
  late final _ctrl = [for (final _ in widget.campos) TextEditingController()];
  bool _admin = false, _busy = false;
  String? _erro;

  @override
  void dispose() {
    for (final c in _ctrl) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _salvar() async {
    final v = [for (final c in _ctrl) c.text];
    final local = widget.validar(v);
    if (local != null) return setState(() => _erro = local);
    setState(() {
      _busy = true;
      _erro = null;
    });
    try {
      await widget.enviar(v, _admin);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      setState(() {
        _erro = e is ApiError ? (e.fields.values.firstOrNull ?? e.message) : errorText(e);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return AlertDialog(
      title: Text(widget.titulo),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < widget.campos.length; i++) ...[
              if (i > 0) SizedBox(height: t.space4),
              TextField(
                controller: _ctrl[i],
                obscureText: widget.campos[i] != 'Usuário',
                decoration: InputDecoration(labelText: widget.campos[i]),
              ),
            ],
            if (widget.comAdmin)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Admin'),
                value: _admin,
                onChanged: (v) => setState(() => _admin = v ?? false),
              ),
            if (_erro != null)
              Padding(
                padding: EdgeInsets.only(top: t.space3),
                child: Text(_erro!, style: TradeType.bodyMd.copyWith(color: t.negative)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: _busy ? null : _salvar, child: const Text('Salvar')),
      ],
    );
  }
}

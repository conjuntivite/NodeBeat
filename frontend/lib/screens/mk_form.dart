import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/shell.dart';

/// Cadastro (id == null) ou edição de uma MK.
class MkFormScreen extends StatefulWidget {
  const MkFormScreen({super.key, required this.api, this.id});
  final ApiClient api;
  final String? id;

  @override
  State<MkFormScreen> createState() => _MkFormScreenState();
}

class _MkFormScreenState extends State<MkFormScreen> {
  final _nome = TextEditingController();
  final _ipTunel = TextEditingController();
  final _ipPublico = TextEditingController();
  final _usuario = TextEditingController();
  final _senha = TextEditingController();
  final _senhaRw = TextEditingController();
  bool _temRw = false;
  bool _removerRw = false;
  Map<String, String> _errors = {};
  String? _general;
  bool _semIpsec = false;
  bool _busy = false;
  bool _loaded = false;

  bool get _edit => widget.id != null;

  @override
  void initState() {
    super.initState();
    if (_edit) {
      widget.api.mk(widget.id!).then((m) {
        if (!mounted) return;
        setState(() {
          _nome.text = m.nome;
          _ipTunel.text = m.ipTunel;
          _ipPublico.text = m.ipPublico;
          _semIpsec = m.semIpsec;
          if (m.semIpsec) _ipTunel.clear();
          _usuario.text = m.usuario;
          _temRw = m.temRw;
          _loaded = true;
        });
      }).catchError((Object e) {
        if (mounted && !sessionExpired(context, e)) setState(() => _general = errorText(e));
      });
    } else {
      _loaded = true;
    }
  }

  @override
  void dispose() {
    for (final c in [_nome, _ipTunel, _ipPublico, _usuario, _senha, _senhaRw]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final errors = <String, String>{
      for (final (k, c) in [('nome', _nome), if (!_semIpsec) ('ip_tunel', _ipTunel), ('ip_publico', _ipPublico), ('usuario', _usuario)])
        if (c.text.trim().isEmpty) k: 'Obrigatório',
      if (!_edit && _senha.text.isEmpty) 'senha': 'Obrigatório',
    };
    if (errors.isNotEmpty) {
      setState(() {
        _errors = errors;
        _general = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _errors = {};
      _general = null;
    });
    final input = MkInput(
      nome: _nome.text.trim(),
      ipTunel: _semIpsec ? '' : _ipTunel.text.trim(),
      semIpsec: _semIpsec,
      ipPublico: _ipPublico.text.trim(),
      usuario: _usuario.text.trim(),
      senha: _senha.text.isEmpty ? null : _senha.text,
      senhaRw: _senhaRw.text.isEmpty ? null : _senhaRw.text,
      removerRw: _removerRw && _senhaRw.text.isEmpty,
    );
    try {
      final nav = Navigator.of(context);
      if (_edit) {
        await widget.api.updateMk(widget.id!, input);
        if (nav.canPop()) {
          nav.pop();
        } else {
          nav.pushReplacementNamed('/mk/${widget.id}'); // deep link: nada por baixo
        }
      } else {
        final id = await widget.api.createMk(input);
        nav.pushReplacementNamed('/mk/$id', arguments: true); // abre a escolha de interfaces
      }
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      setState(() {
        const known = {'nome', 'ip_tunel', 'ip_publico', 'usuario', 'senha', 'senha_rw'};
        _errors = e is ApiError ? {for (final k in e.fields.keys) if (known.contains(k)) k: e.fields[k]!} : {};
        _general = _errors.isEmpty ? errorText(e) : null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String key, String label, TextEditingController c, {bool secret = false, String? hint}) => Padding(
        padding: EdgeInsets.only(bottom: tokensOf(context).space4),
        child: TextField(
          controller: c,
          obscureText: secret,
          decoration: InputDecoration(labelText: label, hintText: hint, errorText: _errors[key]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return AppShell(
      ativo: 'mk',
      titulo: _edit ? 'Editar MK' : 'Nova MK',
      migalhas: Migalhas(anterior: 'MKs', atual: _edit ? 'Editar' : 'Nova MK', aoVoltar: () => voltar(context)),
      body: !_loaded
          ? Center(
              child: _general == null
                  ? const CircularProgressIndicator()
                  : Text(_general!, style: TradeType.bodyMd.copyWith(color: t.negative)))
          : Center(
              child: SingleChildScrollView(
                padding: margemPagina(context),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: TradeCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _field('nome', 'Condomínio', _nome),
                      Row(children: [
                        Checkbox(value: _semIpsec, onChanged: (v) => setState(() => _semIpsec = v ?? false)),
                        const Expanded(child: Text('Sem IPsec (acesso pelo IP público)')),
                      ]),
                      if (!_semIpsec) _field('ip_tunel', 'IP no túnel', _ipTunel),
                      _field('ip_publico', 'IP público', _ipPublico),
                      _field('usuario', 'Usuário da API', _usuario),
                      _field('senha', 'Senha da API', _senha, secret: true, hint: _edit ? 'deixe vazio para manter' : null),
                      _field('senha_rw', 'Senha de alterações (nodebeat-rw)', _senhaRw,
                          secret: true, hint: _edit ? 'deixe vazio para manter' : null),
                      if (_edit && _temRw)
                        GestureDetector(
                          onTap: () => setState(() => _removerRw = !_removerRw),
                          child: Row(children: [
                            Checkbox(value: _removerRw, onChanged: (v) => setState(() => _removerRw = v ?? false)),
                            const Expanded(child: Text('Remover senha de alterações')),
                          ]),
                        ),
                      if (_general != null)
                        Padding(
                          padding: EdgeInsets.only(bottom: t.space4),
                          child: Semantics(
                              liveRegion: true, child: Text(_general!, style: TradeType.bodySm.copyWith(color: t.negative))),
                        ),
                      FilledButton(onPressed: _busy ? null : _save, child: const Text('Salvar')),
                    ]),
                  ),
                ),
              ),
            ),
    );
  }
}

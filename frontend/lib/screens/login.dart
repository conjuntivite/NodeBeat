import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../sessao.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, this.depois = '/painel'});
  final ApiClient api;
  final String depois; // rota depois do login

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.login(_user.text.trim(), _pass.text);
      await carregarSessao(widget.api);
      if (mounted) Navigator.of(context).pushReplacementNamed(widget.depois);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Não foi possível conectar ao servidor');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget campo(String rotulo, Widget controle) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ExcludeSemantics(child: Text(rotulo, style: TradeType.label.copyWith(color: t.fgPrimary))),
          SizedBox(height: t.space1),
          Semantics(label: rotulo, child: controle), // rótulo acima do campo (Field), nome acessível no campo
        ]);
    return Scaffold(
      backgroundColor: t.bgSubtle,
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: Padding(padding: EdgeInsets.all(t.space4), child: const ThemeToggle()),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(t.space4),
                child: Container(
                  width: 380,
                  padding: EdgeInsets.all(t.space8),
                  decoration: BoxDecoration(
                    color: t.bgSurface,
                    borderRadius: BorderRadius.circular(t.radiusLg),
                    border: Border.all(color: t.borderSubtle),
                    boxShadow: [BoxShadow(color: dark ? const Color(0x66000000) : t.fgPrimary.withValues(alpha: .10), blurRadius: 2, offset: const Offset(0, 1))],
                  ),
                  child: AutofillGroup(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Image.asset(dark ? 'assets/brand/nodebeat-icon-dark.png' : 'assets/brand/nodebeat-icon-light.png',
                            width: 40, height: 40, excludeFromSemantics: true),
                        SizedBox(width: t.space3),
                        Flexible(
                          child: Semantics(
                            header: true,
                            child: Text('NodeBeat',
                                style: TradeType.displayXl.copyWith(fontSize: 40, height: 44 / 40, letterSpacing: -.5, color: t.fgPrimary)),
                          ),
                        ),
                      ]),
                      SizedBox(height: t.space1),
                      Text('Entre para acessar o painel.', style: TradeType.bodyLg.copyWith(color: t.fgSecondary)),
                      SizedBox(height: t.space4),
                      campo(
                          'Usuário',
                          TextField(
                            controller: _user,
                                                        autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                          )),
                      SizedBox(height: t.space4),
                      campo(
                          'Senha',
                          TextField(
                            controller: _pass,
                            obscureText: true,
                            autofillHints: const [AutofillHints.password],
                            onSubmitted: (_) => _submit(),
                          )),
                      if (_error != null) ...[
                        SizedBox(height: t.space3),
                        Semantics(liveRegion: true, child: Text(_error!, style: TradeType.bodySm.copyWith(color: t.negative))),
                      ],
                      SizedBox(height: t.space4),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            padding: EdgeInsets.symmetric(horizontal: t.space6, vertical: 13), textStyle: TradeType.bodyLg.copyWith(fontWeight: FontWeight.w500)),
                        onPressed: _busy ? null : _submit,
                        child: const Text('Entrar'),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

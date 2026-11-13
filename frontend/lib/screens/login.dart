import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api});
  final ApiClient api;

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
      if (mounted) Navigator.of(context).pushReplacementNamed('/painel');
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
    return Scaffold(
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
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Container(
                    padding: EdgeInsets.all(t.space6),
                    decoration: BoxDecoration(
                      color: t.bgSurface,
                      borderRadius: BorderRadius.circular(t.radiusXl),
                      border: Border.all(color: t.borderSubtle),
                    ),
                    child: AutofillGroup(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text('// NODEBEAT', style: TradeType.eyebrow.copyWith(color: t.fgMuted)),
                        SizedBox(height: t.space1),
                        Text('Acesso ao painel', style: TradeType.heading2.copyWith(color: t.fgPrimary)),
                        SizedBox(height: t.space6),
                        TextField(
                          controller: _user,
                          decoration: const InputDecoration(labelText: 'Usuário'),
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next,
                        ),
                        SizedBox(height: t.space4),
                        TextField(
                          controller: _pass,
                          decoration: const InputDecoration(labelText: 'Senha'),
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => _submit(),
                        ),
                        if (_error != null) ...[
                          SizedBox(height: t.space3),
                          Text(_error!, style: TradeType.bodySm.copyWith(color: t.negative)),
                        ],
                        SizedBox(height: t.space6),
                        FilledButton(onPressed: _busy ? null : _submit, child: const Text('Entrar')),
                      ]),
                    ),
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

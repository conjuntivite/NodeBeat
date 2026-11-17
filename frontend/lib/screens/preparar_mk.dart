import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../mk_script.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';

/// Passo a passo + script RouterOS para pôr uma MK no NodeBeat. O script é montado aqui; a senha não vai ao servidor.
class PrepararMkScreen extends StatefulWidget {
  const PrepararMkScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<PrepararMkScreen> createState() => _PrepararMkScreenState();
}

class _PrepararMkScreenState extends State<PrepararMkScreen> {
  PrepararMkInfo? _info;
  String? _error;
  String _senha = gerarSenha();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final i = await widget.api.prepararMk();
      if (mounted) setState(() => _info = i);
    } catch (e) {
      if (mounted && !sessionExpired(context, e)) setState(() => _error = errorText(e));
    }
  }

  Future<void> _copiar(String texto, String aviso) async {
    await Clipboard.setData(ClipboardData(text: texto));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(aviso)));
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final i = _info;
    return Scaffold(
      appBar: AppBar(
        leading: backFallback(context),
        backgroundColor: t.bgPage,
        title: Text('Preparar MK', style: TradeType.heading3.copyWith(color: t.fgPrimary)),
        actions: [const ThemeToggle(), SizedBox(width: t.space2)],
      ),
      body: i == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!, style: TradeType.bodyMd.copyWith(color: t.negative)))
          : ListView(padding: EdgeInsets.all(t.space6), children: [
              _novaMk(context, t, i),
              SizedBox(height: t.space4),
              _card(t, 'MK já cadastrada: liberar o botão Reiniciar',
                  'Cole no terminal da MK (logado como admin). Só acrescenta a permissão de reinício ao usuário monitor.',
                  scriptLiberarReinicio, 'copiar-reinicio', 'Comando copiado'),
              SizedBox(height: t.space4),
              _card(t, 'Desfazer tudo', 'Remove da MK o usuário, o grupo, os certificados e as regras de firewall, e desliga a api-ssl.',
                  scriptDesfazer, 'copiar-desfazer', 'Comando copiado'),
            ]),
    );
  }

  Widget _novaMk(BuildContext context, TradeTokens t, PrepararMkInfo i) {
    final faltam = [
      if (i.ipOrigem == null) 'NODEBEAT_IP_ORIGEM',
      if (i.ipsSede.isEmpty) 'NODEBEAT_IPS_PUBLICOS_SEDE',
    ];
    final texto = TradeType.bodyMd.copyWith(color: t.fgSecondary);
    if (faltam.isNotEmpty) {
      return TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Nova MK', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space3),
          Text('O script precisa de ${faltam.join(' e ')} no deploy/.env do servidor. Preencha e reinicie o NodeBeat.',
              style: TradeType.bodyMd.copyWith(color: t.negative)),
        ]),
      );
    }
    final script = scriptPreparar(ipOrigem: i.ipOrigem!, ipsSede: i.ipsSede, senha: _senha);
    Widget passo(String n, String s) => Padding(
          padding: EdgeInsets.only(bottom: t.space2),
          child: Text('$n. $s', style: TradeType.bodyMd.copyWith(color: t.fgPrimary)),
        );
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Nova MK', style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        passo('1', 'Copie o script e cole no terminal da MK: Winbox (logado como admin) → New Terminal.'),
        passo('2', 'Ele descobre sozinho a versão, a WAN e os IPs. Se algo não bater, para sem alterar nada e diz o motivo.'),
        passo('3', 'Ele mostra o IP do túnel, o IP público e a senha. Cadastre a MK no painel com eles e o usuário monitor.'),
        passo('4', 'Confira no terminal: /user group print where name=monitor deve mostrar read, api e reboot sem "!".'),
        SizedBox(height: t.space3),
        Wrap(spacing: t.space3, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Senha do monitor:', style: texto),
          SelectableText(_senha, key: const Key('senha'), style: dataStyle(context, TradeType.dataSm)),
          TextButton(onPressed: () => setState(() => _senha = gerarSenha()), child: const Text('Gerar outra senha')),
        ]),
        SizedBox(height: t.space3),
        _codigo(t, script, const Key('script-preparar')),
        SizedBox(height: t.space3),
        FilledButton(
          key: const Key('copiar-preparar'),
          onPressed: () => _copiar(script, 'Script copiado'),
          child: const Text('Copiar script'),
        ),
        SizedBox(height: t.space3),
        Text('Rodar de novo numa MK já cadastrada troca a senha do monitor: atualize no cadastro (Editar). '
            'O script também troca o certificado e os IPs permitidos da api-ssl: outra ferramenta que use a api-ssl perde o acesso.',
            style: texto),
      ]),
    );
  }

  Widget _card(TradeTokens t, String titulo, String texto, String comando, String chave, String aviso) => TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(titulo, style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space3),
          Text(texto, style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          SizedBox(height: t.space3),
          _codigo(t, comando, null),
          SizedBox(height: t.space3),
          OutlinedButton(key: Key(chave), onPressed: () => _copiar(comando, aviso), child: const Text('Copiar')),
        ]),
      );

  Widget _codigo(TradeTokens t, String texto, Key? key) => Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 360),
        padding: EdgeInsets.all(t.space4),
        decoration: BoxDecoration(
          color: t.bgElevated,
          borderRadius: BorderRadius.circular(t.radiusMd),
          border: Border.all(color: t.borderSubtle),
        ),
        child: SingleChildScrollView(
          child: SelectableText(texto, key: key, style: dataStyle(context, TradeType.dataSm)),
        ),
      );
}

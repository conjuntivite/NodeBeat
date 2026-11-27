import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../mk_script.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';
import '../widgets/shell.dart';

/// A cópia às vezes perde a "{" do começo e o terminal roda linha a linha (as variáveis somem).
const avisoWinbox = 'O Winbox continua na porta 8291. Se a operadora bloquear a 8291, entre pelo IP público na 18291 '
    '(<ip>:18291), que a MK leva para a 8291.';

const avisoColagem = 'Se o terminal mostrar "invalid value" ou "expected end of command", a colagem perdeu parte do script '
    '(a "{" do começo). Copie e cole de novo o script inteiro: ele pode ser repetido.';

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
  String _senhaRw = gerarSenha();

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
    return AppShell(
      ativo: 'preparar',
      titulo: 'Preparar MK',
      body: i == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!, style: TradeType.bodyMd.copyWith(color: t.negative)))
          : ListView(padding: margemPagina(context), children: [
              _novaMk(context, t, i),
              SizedBox(height: t.space4),
              _reinicioPublico(t, i),
              SizedBox(height: t.space4),
              _alteracoes(context, t, i),
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
        Text(avisoWinbox, style: texto),
        SizedBox(height: t.space3),
        Text(avisoColagem, style: texto),
        SizedBox(height: t.space3),
        Text('Rodar de novo numa MK já cadastrada troca a senha do monitor: atualize no cadastro (Editar). '
            'O script também troca o certificado e os IPs permitidos da api-ssl: outra ferramenta que use a api-ssl perde o acesso.',
            style: texto),
      ]),
    );
  }

  /// Sem os IPs da sede o script só reabriria para o próprio NodeBeat: não mostra.
  Widget _reinicioPublico(TradeTokens t, PrepararMkInfo i) {
    const titulo = 'MK já cadastrada: liberar o botão Reiniciar';
    if (i.ipOrigem == null || i.ipsSede.isEmpty) {
      return TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(titulo, style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space3),
          Text(i.ipsSede.isEmpty ? 'Configure NODEBEAT_IPS_PUBLICOS_SEDE no servidor' : 'Configure NODEBEAT_IP_ORIGEM no servidor',
              style: TradeType.bodyMd.copyWith(color: t.negative)),
        ]),
      );
    }
    return _card(
        t,
        titulo,
        'Cole no terminal da MK (logado como admin). Dá ao usuário monitor a permissão de reinício e faz a api-ssl '
            'aceitar também os IPs públicos da sede, para o botão Reiniciar funcionar até com o túnel caído. Substitui os IPs permitidos na api-ssl e no usuário monitor (outra '
            'ferramenta que use a api-ssl perde o acesso). Não troca a senha do usuário monitor. $avisoColagem',
        scriptLiberarReinicio(ipOrigem: i.ipOrigem!, ipsSede: i.ipsSede),
        'copiar-reinicio',
        'Script copiado');
  }

  /// Cria o usuário nodebeat-rw; precisa dos mesmos IPs do servidor que o Nova MK.
  Widget _alteracoes(BuildContext context, TradeTokens t, PrepararMkInfo i) {
    const titulo = 'MK já cadastrada: permitir alterações pelo NodeBeat';
    final faltam = [
      if (i.ipOrigem == null) 'NODEBEAT_IP_ORIGEM',
      if (i.ipsSede.isEmpty) 'NODEBEAT_IPS_PUBLICOS_SEDE',
    ];
    if (faltam.isNotEmpty) {
      return TradeCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(titulo, style: TradeType.heading4.copyWith(color: t.fgPrimary)),
          SizedBox(height: t.space3),
          Text('O script precisa de ${faltam.join(' e ')} no servidor.', style: TradeType.bodyMd.copyWith(color: t.negative)),
        ]),
      );
    }
    final script = scriptLiberarAlteracoes(ipOrigem: i.ipOrigem!, ipsSede: i.ipsSede, senha: _senhaRw);
    return TradeCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(titulo, style: TradeType.heading4.copyWith(color: t.fgPrimary)),
        SizedBox(height: t.space3),
        Text(
            'Cria o usuário nodebeat-rw, que o NodeBeat usa para alterar dados da MK: liberar portas (port forward) e trocar o peer do IPsec. '
            'O usuário monitor continua só leitura. Depois de colar, preencha a senha em Editar MK → Senha de alterações. '
            'Rodar de novo troca a senha.',
            style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        SizedBox(height: t.space3),
        Wrap(spacing: t.space3, runSpacing: t.space2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Senha do nodebeat-rw:', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
          SelectableText(_senhaRw, key: const Key('senha-alteracoes'), style: dataStyle(context, TradeType.dataSm)),
          TextButton(
              key: const Key('outra-senha-alteracoes'),
              onPressed: () => setState(() => _senhaRw = gerarSenha()),
              child: const Text('Gerar outra senha')),
        ]),
        SizedBox(height: t.space3),
        _codigo(t, script, null),
        SizedBox(height: t.space3),
        FilledButton(
          key: const Key('copiar-alteracoes'),
          onPressed: () => _copiar(script, 'Script copiado'),
          child: const Text('Copiar script'),
        ),
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

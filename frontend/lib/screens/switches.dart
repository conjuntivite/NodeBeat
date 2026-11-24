import 'package:material_ui/material_ui.dart';

import '../api/client.dart';
import '../theme/theme.dart';
import '../theme/tokens.g.dart';
import '../widgets/common.dart';

/// Problema = offline ou erro de acesso; "desconhecido" é só aguardando a primeira leitura.
bool equipamentoComProblema(Equipamento e) {
  final s = e.estado?['status'];
  return s == 'offline' || s == 'erro_acesso';
}

/// Lista de switches agrupada por local (Sede primeiro) e diálogo de cadastro.
class SwitchesTab extends StatelessWidget {
  const SwitchesTab({super.key, required this.api, required this.equipamentos, required this.mks, required this.onChanged});
  final ApiClient api;
  final List<Equipamento> equipamentos;
  final List<MkRow> mks;
  final VoidCallback onChanged;

  Future<void> _adicionar(BuildContext context) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _AdicionarSwitch(api: api, mks: mks));
    if (ok == true) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final grupos = <String, List<Equipamento>>{};
    for (final e in equipamentos) {
      grupos.putIfAbsent(e.localNome ?? 'Sem local', () => []).add(e);
    }
    final nomes = grupos.keys.toList()
      ..sort((a, b) => a == 'Sede' ? -1 : b == 'Sede' ? 1 : a.toLowerCase().compareTo(b.toLowerCase()));
    return ListView(
      padding: EdgeInsets.all(t.space6),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => _adicionar(context),
            icon: const Icon(Icons.add, size: 20),
            label: const Text('Adicionar switch'),
          ),
        ),
        SizedBox(height: t.space6),
        if (equipamentos.isEmpty)
          Text('Nenhum switch ainda.', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
        for (final n in nomes) ...[
          Padding(
            padding: EdgeInsets.only(bottom: t.space2),
            child: Text(n, style: TradeType.label.copyWith(color: t.fgSecondary)),
          ),
          TradeCard(
            child: Column(children: [for (final e in grupos[n]!) _Linha(e)]),
          ),
          SizedBox(height: t.space4),
        ],
      ],
    );
  }
}

class _Linha extends StatelessWidget {
  const _Linha(this.e);
  final Equipamento e;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final status = '${e.estado?['status'] ?? 'desconhecido'}';
    final cor = status == 'no_ar' ? t.positive : equipamentoComProblema(e) ? t.negative : t.fgSecondary;
    final rel = relativo(e.estado?['desde']);
    return InkWell(
      key: ValueKey('switch-${e.id}'),
      onTap: () => Navigator.of(context).pushNamed('/switch/${e.id}'),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: t.space3),
        child: Row(
          children: [
            Semantics(
              label: status == 'no_ar' ? 'No ar' : equipamentoComProblema(e) ? 'Com problema' : 'Aguardando',
              child: Container(width: 12, height: 12, decoration: BoxDecoration(color: cor, shape: BoxShape.circle)),
            ),
            SizedBox(width: t.space3),
            Expanded(
              child: Text(e.nome, style: TradeType.bodyMd.copyWith(color: t.fgPrimary, fontWeight: FontWeight.w600)),
            ),
            Text('${e.portasTotal} portas · ${e.portasUp} com link', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
            if (rel.isNotEmpty) ...[
              SizedBox(width: t.space4),
              Text('há $rel', style: TradeType.bodyMd.copyWith(color: t.fgSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}

class _AdicionarSwitch extends StatefulWidget {
  const _AdicionarSwitch({required this.api, required this.mks});
  final ApiClient api;
  final List<MkRow> mks;

  @override
  State<_AdicionarSwitch> createState() => _AdicionarSwitchState();
}

class _AdicionarSwitchState extends State<_AdicionarSwitch> {
  final _nome = TextEditingController(), _ip = TextEditingController(), _community = TextEditingController();
  String _local = 'sede';
  bool _busy = false;
  String? _erro;

  @override
  void dispose() {
    _nome.dispose();
    _ip.dispose();
    _community.dispose();
    super.dispose();
  }

  Future<void> _salvar() async {
    setState(() {
      _busy = true;
      _erro = null;
    });
    try {
      final c = _community.text.trim();
      await widget.api.criarEquipamento(
        tipo: 'switch',
        nome: _nome.text.trim(),
        ip: _ip.text.trim(),
        local: _local,
        community: c.isEmpty ? null : c,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted || sessionExpired(context, e)) return;
      setState(() {
        _erro = errorText(e);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return AlertDialog(
      title: const Text('Adicionar switch'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _nome, decoration: const InputDecoration(labelText: 'Nome')),
              SizedBox(height: t.space4),
              TextField(controller: _ip, decoration: const InputDecoration(labelText: 'IP')),
              SizedBox(height: t.space4),
              DropdownButtonFormField<String>(
                initialValue: _local,
                decoration: const InputDecoration(labelText: 'Local'),
                items: [
                  const DropdownMenuItem(value: 'sede', child: Text('Sede')),
                  for (final m in widget.mks) DropdownMenuItem(value: m.id, child: Text(m.nome)),
                ],
                onChanged: (v) => setState(() => _local = v ?? 'sede'),
              ),
              SizedBox(height: t.space4),
              TextField(
                controller: _community,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Community', hintText: 'em branco = a padrão'),
              ),
              if (_erro != null)
                Padding(
                  padding: EdgeInsets.only(top: t.space3),
                  child: Text(_erro!, style: TradeType.bodyMd.copyWith(color: t.negative)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: _busy ? null : _salvar, child: const Text('Salvar')),
      ],
    );
  }
}

/// Provisório: a Task 11 troca por o detalhe do switch.
class SwitchDetailScreen extends StatelessWidget {
  const SwitchDetailScreen(this.api, this.id, {super.key});
  final ApiClient api;
  final String id;

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(leading: backFallback(context)), body: const SizedBox());
}

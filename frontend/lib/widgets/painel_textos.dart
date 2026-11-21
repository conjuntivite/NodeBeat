import '../api/client.dart';

/// Frase do card de situação: o veredito do painel em uma linha.
String fraseSituacao(PainelEventos d) {
  if (d.resumoEstado['acesso']?.estado == 'critico') {
    return 'Atenção: houve login de fora aceito. Veja o detalhe em Acesso.';
  }
  final vermelhas = d.porMk.where((m) => m.semaforo == 'vermelho').length;
  if (vermelhas > 0) return 'Sem invasão detectada, mas $vermelhas ${vermelhas == 1 ? 'MK' : 'MKs'} em vermelho.';
  if ((d.resumo['acesso'] ?? 0) > 0) return 'Sem invasão. A rede está sob varredura constante, o que é esperado.';
  return 'Tudo calmo.';
}

const explicacaoCategoria = {
  'acesso': 'Tentativas de entrar nas MKs vindas da internet (login, SSH, Winbox). Toda MK com IP público recebe isso '
      'todos os dias. Só vira problema se algum login der certo.',
  'autenticacao': 'Senhas erradas vindas da rede interna e falhas de PPPoE de clientes. Costuma ser cliente com senha '
      'trocada ou roteador antigo.',
  'vpn': 'Falhas ao negociar o túnel entre a MK e a sede. Poucas por dia é normal; várias seguidas em uma MK indicam '
      'túnel instável.',
  'erros': 'Problemas na MK ou no cabo: reinícios, interface que caiu, colisão. Se subir acima do normal, veja qual MK '
      'concentra.',
};

String rotuloEstado(String estado) => switch (estado) {
      'esperado' => 'Esperado',
      'normal' => 'Normal',
      'atencao' => 'Atenção',
      'critico' => 'Crítico',
      _ => estado,
    };

/// "↗ +4% vs. média 7 dias"; "—" quando não há base de comparação.
String textoDelta(int? pct) {
  if (pct == null) return '—';
  final seta = pct > 0 ? '↗ +' : pct < 0 ? '↘ −' : '→ ';
  return '$seta${pct.abs()}% vs. média 7 dias';
}

/// Aviso quando uma MK concentra 25% ou mais dos eventos; `null` caso contrário.
String? notaConcentracao(List<(String, int)> porMk) {
  final total = porMk.fold<int>(0, (a, e) => a + e.$2);
  if (total == 0) return null;
  final topo = porMk.reduce((a, b) => b.$2 > a.$2 ? b : a);
  final pct = (topo.$2 * 100 / total).round();
  if (pct < 25) return null;
  return '${topo.$1} concentra $pct% dos eventos. Confirme se ela precisa ter SSH/Winbox aberto para a internet.';
}

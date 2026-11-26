import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/api/client.dart';
import 'package:nodebeat/ataques/paletas.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/widgets/mapa_ataques.dart';

Future<void> _mostrar(WidgetTester t, {PaletaMapa? paleta}) async {
  t.view.physicalSize = const Size(1280, 720);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: tradeTheme(Brightness.dark),
    home: Scaffold(body: MapaAtaques(api: ApiClient(client: MockClient((_) async => http.Response('', 404))), paleta: paleta)),
  ));
  await t.pump();
  await t.pump();
}

void main() {
  test('paletasCompletas', () {
    expect([for (final p in paletasMapa) p.id], ['ardosia', 'cinza', 'noite', 'oceano', 'grafite', 'papel', 'floresta', 'alto']);
    const pink = [0xFFCE2274, 0xFFFF4FA3, 0xFFE868A5];
    for (final p in paletasMapa) {
      expect(p.vias.length, 6, reason: p.id);
      for (final c in [p.fundo, p.terra, p.borda, p.texto, ...p.vias]) {
        expect(pink.contains(c.toARGB32()), isFalse, reason: p.id);
      }
    }
  });

  test('paletaDesconhecidaUsaPadrao', () {
    expect(paletaPorId('xyz').id, 'ardosia');
    expect(paletaPorId(null).id, 'ardosia');
    expect(paletaPorId('papel').id, 'papel');
  });

  test('paletaPadraoPorTema', () {
    expect(paletaPadrao(Brightness.light).id, 'cinza');
    expect(paletaPadrao(Brightness.dark).id, 'ardosia');
  });

  testWidgets('rotulosUsamCorDaPaleta', (t) async {
    final p = paletaPorId('papel');
    await _mostrar(t, paleta: p);
    final cor = t.widget<Text>(find.text('SSH')).style!.color!;
    expect(cor.toARGB32() & 0xFFFFFF, p.texto.toARGB32() & 0xFFFFFF);
  });

  testWidgets('mapaUsaFundoDaPaleta', (t) async {
    final p = paletaPorId('oceano');
    await _mostrar(t, paleta: p);
    expect(find.byWidgetPredicate((w) => w is ColoredBox && w.color == p.fundo), findsOneWidget);
  });
}

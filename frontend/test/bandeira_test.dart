import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nodebeat/theme/theme.dart';
import 'package:nodebeat/theme/tokens.g.dart';
import 'package:nodebeat/widgets/bandeira.dart';

void main() {
  testWidgets('bandeiraMostraImagem', (t) async {
    await t.pumpWidget(const MaterialApp(home: Bandeira('BR')));
    final img = t.widget<Image>(find.byType(Image));
    expect((img.image as AssetImage).assetName, 'assets/bandeiras/br.png');
    expect(img.width, 20);
    expect(img.height, 15);
  });

  testWidgets('bandeiraTemBordaSutil', (t) async {
    await t.pumpWidget(MaterialApp(theme: tradeTheme(Brightness.light), home: const Align(child: Bandeira('BR'))));
    await t.pump();
    final box = t.widget<DecoratedBox>(find.descendant(of: find.byType(Bandeira), matching: find.byType(DecoratedBox)));
    expect((box.decoration as BoxDecoration).border, Border.all(color: TradeTokens.light.borderSubtle));
    expect(t.getSize(find.byType(Bandeira)), const Size(20, 15));
  });

  testWidgets('bandeiraDesconhecidaNaoQuebra', (t) async {
    for (final cc in [null, '', 'ZZ']) {
      await t.pumpWidget(MaterialApp(home: Align(child: Bandeira(cc))));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(t.getSize(find.byType(Bandeira)), const Size(20, 15));
    }
  });
}

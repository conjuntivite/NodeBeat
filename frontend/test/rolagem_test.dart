import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nodebeat/main.dart';

void main() {
  // TV com controle/air mouse e touchpad que arrasta: o padrão do Flutter só rola arrastando com toque
  testWidgets('arrastarComMouseRola', (t) async {
    final c = ScrollController();
    await t.pumpWidget(MaterialApp(
      scrollBehavior: const RolagemComMouse(),
      home: ListView(controller: c, children: [for (var i = 0; i < 50; i++) SizedBox(height: 100, child: Text('$i'))]),
    ));
    await t.dragFrom(const Offset(200, 400), const Offset(0, -300), kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();
    expect(c.offset, greaterThan(0));
  });
}

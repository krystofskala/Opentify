import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/widgets/desktop_scroll_assist.dart';

void main() {
  Future<ScrollController> pump(WidgetTester tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: DesktopScrollAssist(
        child: Scaffold(
          body: Column(children: [
            // Vodorovná řada nahoře se přeskakuje, posouvá se svislý seznam.
            SizedBox(
              height: 60,
              child: ListView(scrollDirection: Axis.horizontal, children: [for (var i = 0; i < 30; i++) SizedBox(width: 80, child: Text('h$i'))]),
            ),
            Expanded(
              child: ListView.builder(controller: controller, itemExtent: 50, itemCount: 2000, itemBuilder: (_, i) => Text('row $i')),
            ),
          ]),
        ),
      ),
    ));
    return controller;
  }

  testWidgets('PgDn / PgUp / End / Home posouvají seznam pod kurzorem', (tester) async {
    final controller = await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    await mouse.moveTo(const Offset(400, 310));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(300));
    final afterPage = controller.offset;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();
    expect(controller.offset, lessThan(afterPage));
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(controller.offset, controller.position.maxScrollExtent);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    await mouse.removePointer();
  });

  testWidgets('mezerník přepne přehrávání, v textovém poli píše mezeru', (tester) async {
    var toggles = 0;
    final text = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: DesktopScrollAssist(
        onSpace: () => toggles++,
        child: Scaffold(body: Column(children: [TextField(controller: text), const Text('x')])),
      ),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(toggles, 1);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(toggles, 1);
  });

  testWidgets('klik kolečkem: posun podle vzdálenosti kurzoru, další klik ho ukončí', (tester) async {
    final controller = await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await mouse.addPointer(location: const Offset(400, 200));
    await mouse.down(const Offset(400, 200));
    await mouse.up(); // krátký klik -> posun běží dál
    await tester.pump();
    await mouse.moveTo(const Offset(400, 420)); // kurzor níž -> dolů
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final moved = controller.offset;
    expect(moved, greaterThan(100));
    await mouse.down(const Offset(400, 420)); // další klik = konec
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 16));
    final stopped = controller.offset;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.offset, stopped);
    await mouse.removePointer();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:opentify_client/widgets/glass/glass_tab_bar.dart';

const _items = [
  GlassTabItem(icon: Symbols.home_rounded, label: 'Domů'),
  GlassTabItem(icon: Symbols.search_rounded, label: 'Hledat'),
  GlassTabItem(icon: Symbols.library_music_rounded, label: 'Knihovna'),
  GlassTabItem(icon: Symbols.person_rounded, label: 'Profil'),
];

void main() {
  // #40c: podržení smrštěné kapsle -> kapka začne pod prstem (zleva nad
  // Domů), ne nad aktuální záložkou, a po puštění vybere tab pod prstem.
  testWidgets('external drag starts under the finger, not on the current tab', (tester) async {
    final key = GlobalKey<GlassTabBarState>();
    int? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: GlassTabBar(key: key, items: _items, selectedIndex: 3, onSelected: (i) => selected = i),
      ),
    ));
    final bar = tester.getRect(find.byType(GlassTabBar));
    final finger = Offset(bar.left + 30, bar.bottom - 40);

    key.currentState!.beginExternalDrag(finger);
    await tester.pump(const Duration(milliseconds: 16));
    // Puštěno hned (bez pohybu): dřív kapka teprve jela od Profilu a skončila
    // na něm, teď je od začátku nad Domů.
    key.currentState!.endExternalDrag(0);
    await tester.pumpAndSettle();
    expect(selected, 0);
  });

  testWidgets('external drag follows the finger to another tab', (tester) async {
    final key = GlobalKey<GlassTabBarState>();
    int? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: GlassTabBar(key: key, items: _items, selectedIndex: 0, onSelected: (i) => selected = i),
      ),
    ));
    final bar = tester.getRect(find.byType(GlassTabBar));
    final y = bar.bottom - 40;
    key.currentState!.beginExternalDrag(Offset(bar.left + 30, y));
    await tester.pump(const Duration(milliseconds: 16));
    for (var x = bar.left + 30; x < bar.right - 30; x += 20) {
      key.currentState!.updateExternalDrag(Offset(x, y));
      await tester.pump(const Duration(milliseconds: 16));
    }
    key.currentState!.endExternalDrag(0);
    await tester.pumpAndSettle();
    expect(selected, 3);
  });
}

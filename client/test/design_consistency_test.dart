import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Hlídač jednotného vzhledu (živě: sheet „Charita" bez skla, text ležel
/// přímo přes stránku -- audit to nepoznal). Statická kontrola zdrojáků:
/// - sheet se otevírá jen přes `showGlassSheet` (ne `showModalBottomSheet`),
/// - každý soubor, který `showGlassSheet` volá, má i skleněný podklad
///   (`GlassSheet` / `GlassContainer` / `DraggableScrollableSheet` se sklem).
void main() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  String rel(File f) => f.path.replaceAll(r'\', '/');

  test('sheety jen přes showGlassSheet', () {
    final offenders = [
      for (final f in files)
        if (!rel(f).endsWith('widgets/glass/glass_sheet.dart') && f.readAsStringSync().contains('showModalBottomSheet'))
          rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Použij showGlassSheet + GlassSheet: $offenders');
  });

  test('každý showGlassSheet má skleněný podklad', () {
    final offenders = <String>[];
    for (final f in files) {
      final src = f.readAsStringSync();
      if (!src.contains('showGlassSheet(') && !src.contains('showGlassSheet<')) continue;
      if (rel(f).endsWith('widgets/glass/glass_sheet.dart')) continue;
      final withoutCall = src.replaceAll('showGlassSheet', '');
      final hasGlass = withoutCall.contains('GlassSheet(') || withoutCall.contains('GlassContainer');
      if (!hasGlass) offenders.add(rel(f));
    }
    expect(offenders, isEmpty, reason: 'Obsah sheetu obal do GlassSheet: $offenders');
  });
}

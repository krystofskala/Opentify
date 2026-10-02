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

  // Vizuální audit (2026-10): menu jsou skleněné sheety, ne vyskakovací.
  test('žádné PopupMenuButton', () {
    final offenders = [
      for (final f in files)
        if (f.readAsStringSync().contains('PopupMenuButton')) rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Menu přes showGlassSheet (viz SortButton): $offenders');
  });

  // Horní lišta jen přes SectionAppBar (stejné zpět, průhlednost); holý
  // AppBar jen tam, kde je záměrně jiný (černá karta ke sdílení).
  test('AppBar jen přes SectionAppBar', () {
    const allowed = ['widgets/section_app_bar.dart', 'features/share/share_card_screen.dart'];
    final bare = RegExp(r'(?<![A-Za-z])AppBar\(');
    final offenders = [
      for (final f in files)
        if (!allowed.any((a) => rel(f).endsWith(a)) && bare.hasMatch(f.readAsStringSync())) rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Použij SectionAppBar: $offenders');
  });

  // Jedna podoba hlášek (stejná délka, nová nahradí starou): jen showToast.
  test('hlášky jen přes showToast', () {
    final offenders = [
      for (final f in files)
        if (!rel(f).endsWith('widgets/toast.dart') && f.readAsStringSync().contains('showSnackBar(')) rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Použij showToast / toast: $offenders');
  });

  // Jedna sada ikon (zaoblené Material Symbols), žádné "outline" varianty.
  test('žádné outline ikony', () {
    final outline = RegExp(r'Symbols\.\w*outline');
    final offenders = [
      for (final f in files)
        if (outline.hasMatch(f.readAsStringSync())) rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Použij *_rounded s fill: $offenders');
  });
}

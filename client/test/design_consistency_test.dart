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

  // Červená jen pro srdíčko (jedna barva „líbí se"); jinak colorScheme.error.
  test('Colors.red jen v like_heart', () {
    final red = RegExp(r'Colors\.red');
    final offenders = [
      for (final f in files)
        if (!rel(f).endsWith('widgets/like_heart.dart') && red.hasMatch(f.readAsStringSync())) rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Použij colorScheme.error: $offenders');
  });

  // Akce jsou pod ⋯ (more_horiz) se skleněným sheetem, ne svislé tečky.
  test('žádné more_vert', () {
    final offenders = [
      for (final f in files)
        if (f.readAsStringSync().contains('more_vert')) rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Použij more_horiz: $offenders');
  });

  // Seznam/karty jen přes ViewModeToggle (jeden vzhled přepínače).
  test('přepínač zobrazení jen přes ViewModeToggle', () {
    final offenders = [
      for (final f in files)
        if (!rel(f).endsWith('widgets/view_mode_toggle.dart') && f.readAsStringSync().contains('view_list_rounded'))
          rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Použij ViewModeToggle: $offenders');
  });

  // Ráčny: literální rádiusy a velikosti písma se nesmí přidávat (AppRadii,
  // textTheme). Při úklidu snižuj strop, nikdy nezvyšuj.
  int count(RegExp re) => files.fold(0, (n, f) => n + re.allMatches(f.readAsStringSync()).length);

  test('literální rádiusy jen ubývají', () {
    expect(count(RegExp(r'Radius\.circular\(\d')), lessThanOrEqualTo(22), reason: 'Použij AppRadii / AppShapes');
  });

  test('literální fontSize jen ubývají', () {
    expect(count(RegExp(r'fontSize: \d')), lessThanOrEqualTo(44), reason: 'Použij textTheme');
  });
}

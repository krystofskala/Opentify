import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/release_model.dart';
import '../../theme/design_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/player_bar.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../state/artwork_provider.dart';
import 'artist_screen.dart' show discographyProvider;
import '../../widgets/collection_actions.dart';

const _typeLabels = {'album': 'Album', 'ep': 'EP', 'single': 'Singl', 'compilation': 'Kompilace'};
const _filterLabels = {'all': 'Vše', 'album': 'Alba', 'ep': 'EP', 'single': 'Singly', 'compilation': 'Kompilace'};

const _months = [
  'ledna', 'února', 'března', 'dubna', 'května', 'června', //
  'července', 'srpna', 'září', 'října', 'listopadu', 'prosince',
];

/// "3. května 2016" / "květen 2016" / "2016" -- podle toho, jak přesné datum
/// MusicBrainz zná (často jen rok).
String _dateLabel(String? date) {
  if (date == null || date.length < 4) return 'Datum neznámé';
  final parts = date.split('-');
  if (parts.length >= 3) {
    final day = int.tryParse(parts[2]);
    final month = int.tryParse(parts[1]);
    if (day != null && month != null && month >= 1 && month <= 12) return '$day. ${_months[month - 1]} ${parts[0]}';
  }
  return parts[0];
}

/// Celá diskografie interpreta jako časová osa -- roky vlevo na svislé čáře,
/// vydání chronologicky, ať je vidět, jak šla po sobě. Filtr podle typu a
/// přepnutí pořadí.
class ArtistDiscographyScreen extends ConsumerStatefulWidget {
  const ArtistDiscographyScreen({super.key, required this.artistId, this.initialType = 'all'});

  final String artistId;
  final String initialType;

  @override
  ConsumerState<ArtistDiscographyScreen> createState() => _ArtistDiscographyScreenState();
}

class _ArtistDiscographyScreenState extends ConsumerState<ArtistDiscographyScreen> {
  late String _type = widget.initialType;
  bool _oldestFirst = true;

  @override
  Widget build(BuildContext context) {
    final discography = ref.watch(discographyProvider(widget.artistId));
    return Scaffold(
      appBar: SectionAppBar(
        discography.valueOrNull?.artist.name ?? 'Diskografie',
        actions: [
          IconButton(
            tooltip: _oldestFirst ? 'Od nejnovějších' : 'Od nejstarších',
            icon: Icon(_oldestFirst ? Symbols.arrow_downward_rounded : Symbols.arrow_upward_rounded),
            onPressed: () => setState(() => _oldestFirst = !_oldestFirst),
          ),
        ],
      ),
      bottomNavigationBar: const PlayerBar(),
      body: discography.when(
        data: (data) {
          final types = {for (final r in data.releases) r.releaseType};
          final filters = [
            'all',
            ...['album', 'ep', 'single', 'compilation'].where(types.contains)
          ];
          final type = filters.contains(_type) ? _type : 'all';
          final releases = data.releases.where((r) => type == 'all' || r.releaseType == type).toList()
            ..sort((a, b) {
              // Bez data na konec, ať nerozbíjejí osu.
              final da = a.releaseDate ?? (_oldestFirst ? '9999' : '0000');
              final db = b.releaseDate ?? (_oldestFirst ? '9999' : '0000');
              return _oldestFirst ? da.compareTo(db) : db.compareTo(da);
            });
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (filters.length > 2)
                        GlassSegmentedControl<String>(
                          segments: [for (final f in filters) GlassSegment(value: f, label: _filterLabels[f]!)],
                          selected: type,
                          onChanged: (value) => setState(() => _type = value),
                        ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _summary(releases),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: releases.length,
                itemBuilder: (context, i) {
                  final release = releases[i];
                  final year = release.yearLabel;
                  final firstOfYear = i == 0 || releases[i - 1].yearLabel != year;
                  final lastOfYear = i == releases.length - 1 || releases[i + 1].yearLabel != year;
                  return _TimelineRow(
                    release: release,
                    year: firstOfYear ? year : null,
                    isFirst: i == 0,
                    isLast: i == releases.length - 1,
                    endsYear: lastOfYear,
                  );
                },
              ),
              SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + MediaQuery.paddingOf(context).bottom)),
            ],
          );
        },
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Diskografii se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(discographyProvider(widget.artistId)),
        ),
      ),
    );
  }

  String _summary(List<ReleaseModel> releases) {
    final years = releases.map((r) => int.tryParse(r.yearLabel)).whereType<int>().toList()..sort();
    final n = releases.length;
    if (years.isEmpty) return '$n vydání';
    final span = years.first == years.last ? '${years.first}' : '${years.first}–${years.last}';
    return '$n vydání · $span';
  }
}

/// Jeden řádek osy: vlevo rok (jen u prvního vydání roku) a tečka na čáře,
/// vpravo obal, název, typ a datum.
class _TimelineRow extends ConsumerWidget {
  const _TimelineRow({
    required this.release,
    required this.year,
    required this.isFirst,
    required this.isLast,
    required this.endsYear,
  });

  final ReleaseModel release;
  final String? year;
  final bool isFirst;
  final bool isLast;
  final bool endsYear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cover = release.coverImageUrl ??
        ref.watch(recordingArtworkProvider((releaseId: release.id, artistId: release.artistId))).valueOrNull;
    final lineColor = scheme.outlineVariant;
    return InkWell(
      onTap: () => context.push('/releases/${release.id}'),
      onLongPress: () => showCollectionActions(
        context,
        kind: CollectionKind.album,
        id: release.id,
        title: release.title,
        subtitle: release.yearLabel,
        imageUrl: cover,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 64,
              child: Padding(
                padding: const EdgeInsets.only(left: AppSpacing.md, top: AppSpacing.sm),
                child: year == null
                    ? null
                    : Text(
                        year!,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900, color: scheme.primary),
                      ),
              ),
            ),
            // Svislá čára s tečkou u každého vydání (větší na začátku roku).
            SizedBox(
              width: 22,
              child: CustomPaint(
                painter: _AxisPainter(
                  color: lineColor,
                  dot: year != null ? scheme.primary : scheme.onSurfaceVariant,
                  big: year != null,
                  top: !isFirst,
                  bottom: !isLast,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                    AppSpacing.xs, AppSpacing.xs, AppSpacing.md, endsYear ? AppSpacing.md : AppSpacing.xs),
                child: Row(
                  children: [
                    ClipPath(
                      clipper: ShapeBorderClipper(shape: AppShapes.sm),
                      child: SizedBox(width: 64, height: 64, child: ArtworkImage(url: cover, iconSize: 24)),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(release.title,
                              maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            '${_typeLabels[release.releaseType] ?? release.releaseType} · ${_dateLabel(release.releaseDate)}',
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AxisPainter extends CustomPainter {
  const _AxisPainter(
      {required this.color, required this.dot, required this.big, required this.top, required this.bottom});

  final Color color;
  final Color dot;
  final bool big;
  final bool top;
  final bool bottom;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    const dotY = 40.0; // na úrovni středu obalu
    final line = Paint()
      ..color = color
      ..strokeWidth = 2;
    if (top) canvas.drawLine(Offset(x, 0), Offset(x, dotY), line);
    if (bottom) canvas.drawLine(Offset(x, dotY), Offset(x, size.height), line);
    canvas.drawCircle(Offset(x, dotY), big ? 6 : 4, Paint()..color = dot);
  }

  @override
  bool shouldRepaint(covariant _AxisPainter old) =>
      old.color != color || old.dot != dot || old.big != big || old.top != top || old.bottom != bottom;
}

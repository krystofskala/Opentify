import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recording_model.dart';
import '../theme/design_tokens.dart';
import 'glass/glass.dart';
import 'state_views.dart';
import 'track_collection.dart';
import 'track_tile.dart';

/// "Zobrazit vše" pro řadu skladeb (Home rails, žánr) -- celý seznam ve
/// vytahovacím sheetu se stejnou lištou filtr/řazení/výběr jako album nebo
/// playlist, ne další samostatná obrazovka.
Future<void> showTrackListSheet(
  BuildContext context, {
  required String title,
  List<RecordingModel>? recordings,
  Future<List<RecordingModel>> Function(WidgetRef ref)? load,
}) {
  return showGlassSheet(
    context,
    builder: (context) => _TrackListSheet(title: title, recordings: recordings, load: load),
  );
}

class _TrackListSheet extends ConsumerStatefulWidget {
  const _TrackListSheet({required this.title, this.recordings, this.load});

  final String title;
  final List<RecordingModel>? recordings;
  final Future<List<RecordingModel>> Function(WidgetRef ref)? load;

  @override
  ConsumerState<_TrackListSheet> createState() => _TrackListSheetState();
}

class _TrackListSheetState extends ConsumerState<_TrackListSheet> {
  final _collection = TrackCollectionController();
  late Future<List<RecordingModel>> _future = _fetch();

  Future<List<RecordingModel>> _fetch() =>
      widget.recordings != null ? Future.value(widget.recordings) : widget.load!(ref);

  @override
  void dispose() {
    _collection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => GlassSheet(
        expand: true,
        child: FutureBuilder<List<RecordingModel>>(
          future: _future,
          builder: (context, snapshot) {
            // Úchyt kreslí GlassSheet (stejný ve všech sheetech).
            final header = SliverToBoxAdapter(child: SectionHeader(widget.title));
            if (snapshot.hasError) {
              return CustomScrollView(controller: scrollController, slivers: [
                header,
                SliverToBoxAdapter(
                  child: ErrorState(
                    compact: true,
                    message: 'Nepodařilo se načíst.',
                    onRetry: () => setState(() => _future = _fetch()),
                  ),
                ),
              ]);
            }
            if (!snapshot.hasData) {
              return CustomScrollView(controller: scrollController, slivers: [
                header,
                const SliverToBoxAdapter(child: SkeletonTrackList(count: 8)),
              ]);
            }
            final all = snapshot.data!;
            return ListenableBuilder(
              listenable: _collection,
              builder: (context, _) {
                final visible = _collection.apply(all);
                return CustomScrollView(
                  controller: scrollController,
                  slivers: [
                    header,
                    if (all.isEmpty)
                      const SliverToBoxAdapter(child: EmptyState(compact: true, message: 'Tady zatím nic není.'))
                    else ...[
                      SliverToBoxAdapter(
                        child: TrackCollectionToolbar(
                          controller: _collection,
                          allTracks: all,
                          visibleTracks: visible,
                          sourceLabel: widget.title,
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, AppSpacing.lg),
                        sliver: SliverList.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final r = visible[index];
                            return TrackTile(
                              recording: r,
                              queueRecordings: visible,
                              sourceLabel: widget.title,
                              selectionMode: _collection.selecting,
                              selected: _collection.isSelected(r.id),
                              selectionNumber: _collection.orderOf(r.id),
                              onSelectedChanged: (value) => _collection.toggle(r.id, value),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

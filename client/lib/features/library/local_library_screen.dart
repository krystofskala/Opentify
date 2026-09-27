import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/recording_model.dart';
import '../../state/providers.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/recording_tile.dart';

const _pageSize = 100;

/// Naskenovaná lokální knihovna (`POST /library/scan`, viz Profil) --
/// všechny nahrávky tady jsou vždy `available`, takže na rozdíl od
/// Home/Search jde o čistý seznam k rovnému přehrání, bez provisioning
/// tlačítek/stavů.
class LocalLibraryScreen extends ConsumerStatefulWidget {
  const LocalLibraryScreen({super.key});

  @override
  ConsumerState<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

class _LocalLibraryScreenState extends ConsumerState<LocalLibraryScreen> {
  final List<RecordingModel> _items = [];
  int _total = 0;
  bool _loading = false;
  bool _initialLoadDone = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final page = await ref.read(libraryRepositoryProvider).localTracks(limit: _pageSize, offset: _items.length);
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      setState(() {
        _loading = false;
        _initialLoadDone = true;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _initialLoadDone = false;
    });
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_total == 0 ? 'Knihovna' : 'Knihovna ($_total)')),
      bottomNavigationBar: const PlayerBar(),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: !_initialLoadDone
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _items.isEmpty
                ? Center(child: Text('Nepodařilo se načíst: $_error'))
                : _items.isEmpty
                    ? ListView(
                        children: const [
                          Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Zatím žádné lokální soubory -- spusť sken v Profilu, ať se '
                              'namapovaná knihovna (MUSIC_DIR) zaeviduje.',
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        itemCount: _items.length + (_items.length < _total ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= _items.length) {
                            if (!_loading) {
                              WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                            }
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          return RecordingTile(recording: _items[index]);
                        },
                      ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/listen_later_repository.dart';
import 'audio_player_controller.dart';
import 'providers.dart';

final listenLaterRepositoryProvider = Provider<ListenLaterRepository>(
  (ref) => ListenLaterRepository(ref.watch(apiClientProvider)),
);

/// "Poslechnout později" -- celý seznam; tlačítka po appce se ptají přes
/// `LaterList.find`. Po přehrání skladby se seznam obnoví (server ji mohl
/// přesunout do "Poslechnuto").
final listenLaterProvider = AsyncNotifierProvider<ListenLaterController, LaterList>(ListenLaterController.new);

class ListenLaterController extends AsyncNotifier<LaterList> {
  ListenLaterRepository get _repo => ref.read(listenLaterRepositoryProvider);

  @override
  Future<LaterList> build() {
    // Dohraná skladba mohla přesunout položku do "Poslechnuto" (server
    // započítá poslech) -- při přechodu na další skladbu seznam obnovit.
    ref.listen(audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId), (previous, next) {
      if (previous != null && previous != next && state.valueOrNull?.active.isNotEmpty == true) {
        Future.delayed(const Duration(seconds: 2), refresh);
      }
    });
    return ref.watch(listenLaterRepositoryProvider).list();
  }

  Future<void> refresh() async => state = AsyncData(await _repo.list());

  bool contains(LaterKind kind, String targetId) => state.valueOrNull?.find(kind, targetId) != null;

  Future<LaterItem> add(LaterKind kind, String targetId, {String? note}) async {
    final item = await _repo.add(kind, targetId, note: note);
    final current = state.valueOrNull ?? const LaterList();
    state = AsyncData(
      LaterList(
        active: [item, ...current.active.where((i) => i.id != item.id)],
        listened: current.listened.where((i) => i.id != item.id).toList(),
        reminder: current.reminder,
      ),
    );
    return item;
  }

  Future<void> remove(String itemId) async {
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        LaterList(
          active: current.active.where((i) => i.id != itemId).toList(),
          listened: current.listened.where((i) => i.id != itemId).toList(),
          reminder: current.reminder?.id == itemId ? null : current.reminder,
        ),
      );
    }
    await _repo.remove(itemId);
  }

  Future<void> setNote(String itemId, String note) async {
    await _repo.setNote(itemId, note);
    await refresh();
  }

  Future<void> restore(String itemId) async {
    await _repo.restore(itemId);
    await refresh();
  }

  /// Přepínač z tlačítek po appce (menu skladby, album, interpret) + toast
  /// s možností připsat poznámku.
  Future<void> toggle(BuildContext context, LaterKind kind, String targetId) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final existing = state.valueOrNull?.find(kind, targetId);
    try {
      if (existing != null) {
        await remove(existing.id);
        messenger?.showSnackBar(const SnackBar(content: Text('Odebráno z Poslechnout později')));
        return;
      }
      final item = await add(kind, targetId);
      messenger?.showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Symbols.schedule_rounded, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('Přidáno do Poslechnout později')),
            ],
          ),
          action: context.mounted
              ? SnackBarAction(label: 'Poznámka', onPressed: () => editLaterNote(context, this, item))
              : null,
        ),
      );
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text('Nepodařilo se uložit, zkus to znovu')));
    }
  }
}

/// Dialog na poznámku ("od Honzy", "na roadtrip"...).
Future<void> editLaterNote(BuildContext context, ListenLaterController controller, LaterItem item) async {
  final text = TextEditingController(text: item.note ?? '');
  final note = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Poznámka'),
      content: TextField(
        controller: text,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(hintText: 'Třeba „doporučil Honza" nebo „na roadtrip"'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Zrušit')),
        FilledButton(onPressed: () => Navigator.of(context).pop(text.text), child: const Text('Uložit')),
      ],
    ),
  );
  if (note != null) await controller.setNote(item.id, note);
}

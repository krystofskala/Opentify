import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/device_token.dart' show actAsProfile;

/// Hlášení poslechů (scrobbling) -- server je uloží do historie pro osobní
/// mixy a přepošle do ListenBrainz.
///
/// Poslech, který se nepodaří odeslat (slabý signál na cestě, restart
/// serveru), se neztratí: uloží se v zařízení a odešle se při dalším
/// poslechu. Server stejný poslech (profil, skladba, začátek) zapíše jen
/// jednou, takže opakované odeslání nic nezdvojí.
class ListensRepository {
  const ListensRepository(this._api);

  final ApiClient _api;

  static const _pendingKey = 'listens.pending.v1';
  static const _maxPending = 500;

  Future<void> submitListen({
    required String recordingId,
    required DateTime playedAt,
    required Duration played,
    String? source,
    String? context,
  }) async {
    final body = {
      'recordingId': recordingId,
      'playedAt': playedAt.toUtc().toIso8601String(),
      'durationPlayedMs': played.inMilliseconds,
      if (source != null) 'source': source,
      if (context != null) 'context': context,
    };
    try {
      await _api.postJson('/listens', body: body);
    } on ApiException catch (e) {
      // 404 = skladba už neexistuje (sloučená) -- nemá smysl opakovat.
      if (e.statusCode != 404) await _remember(body);
      rethrow;
    } catch (_) {
      await _remember(body);
      rethrow;
    }
    // Spojení je -- poslat i to, co dřív neprošlo.
    await flushPending();
  }

  Future<void> _remember(Map<String, Object> body) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_pendingKey) ?? <String>[];
      // Poslech patří profilu, za který se teď hraje (admin může jednat za jiný).
      list.add(jsonEncode({...body, 'actAs': actAsProfile}));
      await prefs.setStringList(_pendingKey, list.length > _maxPending ? list.sublist(list.length - _maxPending) : list);
    } catch (_) {}
  }

  // Statické: provider může vytvořit víc instancí, odesílat smí jen jedna.
  static bool _flushing = false;

  /// Odešle uložené poslechy (jen ty hrané za stejný profil jako teď).
  Future<void> flushPending() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_pendingKey) ?? const <String>[];
      if (list.isEmpty) return;
      final keep = <String>[];
      var online = true;
      for (final raw in list) {
        final item = jsonDecode(raw) as Map<String, dynamic>;
        if (!online || item['actAs'] != actAsProfile) {
          keep.add(raw);
          continue;
        }
        try {
          await _api.postJson('/listens', body: Map<String, Object>.from(item..remove('actAs')));
        } on ApiException catch (e) {
          if (e.statusCode != 404) {
            keep.add(raw);
            online = false;
          }
        } catch (_) {
          keep.add(raw);
          online = false; // pořád bez spojení -- zbytek příště
        }
      }
      await prefs.setStringList(_pendingKey, keep);
    } catch (_) {
    } finally {
      _flushing = false;
    }
  }

  Future<void> playingNow(String recordingId) async {
    await _api.postJson('/listens/playing-now', body: {'recordingId': recordingId});
  }
}

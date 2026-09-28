import '../core/api_client.dart';
import '../models/provisioning_model.dart';

/// Tenká vrstva nad provisioning endpointy (docs/openapi.yaml): spouští
/// on-demand obstarání a čte stav jobu jako REST fallback pro zařízení bez
/// aktivního WS spojení — primární cesta je poslech `track.available`/
/// `job.progress` přes RealtimeClient (viz state/provisioning_controller.dart).
class ProvisioningRepository {
  ProvisioningRepository(this._api);

  final ApiClient _api;

  /// `interactive` -- uživatel právě zmáčkl Přehrát a čeká: backend job
  /// zařadí do prioritní fronty a nechá slskd závodit s YouTube. Prefetch
  /// fronty ho posílá bez něj (kvalita má přednost před rychlostí).
  Future<ProvisionResultModel> provision(String recordingId, {bool interactive = false}) async {
    final json = await _api.postJson(
      '/tracks/$recordingId/provision',
      body: interactive ? const {'priority': 'interactive'} : null,
    );
    return ProvisionResultModel.fromJson(json);
  }

  /// `GET /tracks/{id}/loudness` -- korekce hlasitosti v dB, `null` =
  /// backend ji ještě nezměřil (čerstvě obstaraná skladba, viz app/loudness.py).
  Future<double?> loudnessGain(String recordingId) async {
    final json = await _api.getJson('/tracks/$recordingId/loudness');
    return (json['loudnessGainDb'] as num?)?.toDouble();
  }

  Future<ProvisioningJobModel> getJob(String jobId) async {
    final json = await _api.getJson('/jobs/$jobId');
    return ProvisioningJobModel.fromJson(json);
  }

  /// `GET /tracks/{id}/stream` — přímá URL pro audio player. Vyžaduje
  /// `MediaAsset.status == AVAILABLE`, jinak backend vrátí 409.
  String streamUrl(String recordingId) => '${_api.baseUrl}/tracks/$recordingId/stream';
}

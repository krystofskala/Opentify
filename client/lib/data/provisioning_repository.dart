import '../core/api_client.dart';
import '../models/provisioning_model.dart';

/// Tenká vrstva nad provisioning endpointy (docs/openapi.yaml): spouští
/// on-demand obstarání a čte stav jobu jako REST fallback pro zařízení bez
/// aktivního WS spojení — primární cesta je poslech `track.available`/
/// `job.progress` přes RealtimeClient (viz state/provisioning_controller.dart).
class ProvisioningRepository {
  ProvisioningRepository(this._api);

  final ApiClient _api;

  Future<ProvisionResultModel> provision(String recordingId) async {
    final json = await _api.postJson('/tracks/$recordingId/provision');
    return ProvisionResultModel.fromJson(json);
  }

  Future<ProvisioningJobModel> getJob(String jobId) async {
    final json = await _api.getJson('/jobs/$jobId');
    return ProvisioningJobModel.fromJson(json);
  }

  /// `GET /tracks/{id}/stream` — přímá URL pro audio player. Vyžaduje
  /// `MediaAsset.status == AVAILABLE`, jinak backend vrátí 409.
  String streamUrl(String recordingId) => '${_api.baseUrl}/tracks/$recordingId/stream';
}

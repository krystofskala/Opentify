/// 1:1 s `components.schemas.ProvisioningJob` v docs/openapi.yaml.
class ProvisioningJobModel {
  const ProvisioningJobModel({
    required this.id,
    required this.recordingId,
    required this.status,
    required this.attempts,
    this.errorMessage,
  });

  final String id;
  final String recordingId;
  final String status; // PENDING | RUNNING | SUCCEEDED | FAILED | CANCELLED
  final int attempts;
  final String? errorMessage;

  factory ProvisioningJobModel.fromJson(Map<String, dynamic> json) => ProvisioningJobModel(
        id: json['id'] as String,
        recordingId: json['recordingId'] as String,
        status: json['status'] as String,
        attempts: json['attempts'] as int? ?? 0,
        errorMessage: json['errorMessage'] as String?,
      );
}

/// 1:1 s `components.schemas.ProvisionResult` — odpověď `POST /tracks/{id}/provision`.
class ProvisionResultModel {
  const ProvisionResultModel({
    required this.recordingId,
    required this.status,
    this.streamUrl,
    this.job,
    this.loudnessGainDb,
  });

  final String recordingId;
  final String status; // MediaAsset.status
  final String? streamUrl; // vyplněno jen když status == AVAILABLE
  final ProvisioningJobModel? job; // vyplněno jen když se čeká na obstarání (HTTP 202)

  /// Korekce hlasitosti k cíli -14 LUFS (backend app/loudness.py) --
  /// doplňkové pole mimo strict OpenAPI schéma, `null` = ještě neměřeno.
  final double? loudnessGainDb;

  factory ProvisionResultModel.fromJson(Map<String, dynamic> json) => ProvisionResultModel(
        recordingId: json['recordingId'] as String,
        status: json['status'] as String,
        streamUrl: json['streamUrl'] as String?,
        job: json['job'] == null
            ? null
            : ProvisioningJobModel.fromJson(json['job'] as Map<String, dynamic>),
        loudnessGainDb: (json['loudnessGainDb'] as num?)?.toDouble(),
      );
}

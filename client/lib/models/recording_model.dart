import 'availability.dart';

/// 1:1 s `components.schemas.Recording` v docs/openapi.yaml (včetně
/// `previewUrl`, které je doplňkové Deezer pole nad rámec strict schématu —
/// viz backend app/catalog/schemas.py).
class RecordingModel {
  const RecordingModel({
    required this.id,
    this.mbid,
    this.releaseId,
    this.artistId,
    required this.title,
    this.durationMs,
    this.isrc,
    this.trackNumber,
    required this.availability,
    this.previewUrl,
  });

  final String id;
  final String? mbid;
  final String? releaseId;
  final String? artistId;
  final String title;
  final int? durationMs;
  final String? isrc;
  final int? trackNumber;
  final Availability availability;
  final String? previewUrl;

  String get durationLabel {
    if (durationMs == null) return '--:--';
    final totalSeconds = (durationMs! / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  factory RecordingModel.fromJson(Map<String, dynamic> json) => RecordingModel(
        id: json['id'] as String,
        mbid: json['mbid'] as String?,
        releaseId: json['releaseId'] as String?,
        artistId: json['artistId'] as String?,
        title: json['title'] as String,
        durationMs: json['durationMs'] as int?,
        isrc: json['isrc'] as String?,
        trackNumber: json['trackNumber'] as int?,
        availability: availabilityFromJson(json['availability'] as String?),
        previewUrl: json['previewUrl'] as String?,
      );

  RecordingModel copyWith({Availability? availability}) => RecordingModel(
        id: id,
        mbid: mbid,
        releaseId: releaseId,
        artistId: artistId,
        title: title,
        durationMs: durationMs,
        isrc: isrc,
        trackNumber: trackNumber,
        availability: availability ?? this.availability,
        previewUrl: previewUrl,
      );
}

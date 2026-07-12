/// Audio quality level requested from `song/enhance/player/url/v1`.
enum AudioLevel { standard, higher, exhigh, lossless, hires }

extension AudioLevelX on AudioLevel {
  /// Wire value for the `level` field (== enum name).
  String get apiValue => name;

  /// `encodeType` payload field: "flac" for lossless/hires, otherwise "aac".
  String get encodeType =>
      (this == AudioLevel.lossless || this == AudioLevel.hires) ? 'flac' : 'aac';

  /// Bitrate for the download endpoint (`br` field).
  int get downloadBr {
    switch (this) {
      case AudioLevel.standard:
        return 128000;
      case AudioLevel.higher:
        return 192000;
      case AudioLevel.exhigh:
        return 320000;
      case AudioLevel.lossless:
        return 999000;
      case AudioLevel.hires:
        return 999000;
    }
  }
}

/// Resolved play URL (`data[0]` from the player-url endpoint). [url] is null
/// when the caller is not entitled (no MUSIC_U / VIP required).
class PlayUrl {
  final int id;
  final String? url;
  final int br;
  final String type;
  final int size;
  final String? md5;
  final AudioLevel level;

  const PlayUrl({
    required this.id,
    this.url,
    required this.br,
    required this.type,
    required this.size,
    this.md5,
    required this.level,
  });

  factory PlayUrl.fromJson(Map<String, dynamic> json, AudioLevel level) {
    return PlayUrl(
      id: _int(json['id']),
      url: json['url'] as String?,
      br: _int(json['br']),
      type: _str(json['type']),
      size: _int(json['size']),
      md5: json['md5'] as String?,
      level: level,
    );
  }

  bool get isPlayable => url != null;
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';

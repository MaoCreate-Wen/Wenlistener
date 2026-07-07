import 'image_url.dart';

/// A performing artist (`ar[]` entry on Netease song objects).
class Artist {
  final int id;
  final String name;
  final String? picUrl;

  const Artist({required this.id, required this.name, this.picUrl});

  factory Artist.fromJson(Map<String, dynamic> json) {
    return Artist(
      id: _int(json['id']),
      name: _str(json['name']),
      picUrl: httpsImageUrl(json['picUrl'] ?? json['img1v1Url']),
    );
  }

  /// Parses the `ar` / `artists` array.
  static List<Artist> listFromJson(List<dynamic>? json) {
    if (json == null) return const <Artist>[];
    return json
        .whereType<Map>()
        .map((e) => Artist.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';

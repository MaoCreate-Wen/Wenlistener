import 'image_url.dart';

/// An album (`al` field on Netease song objects).
class Album {
  final int id;
  final String name;
  final String? picUrl;

  const Album({required this.id, required this.name, this.picUrl});

  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: _int(json['id']),
      name: _str(json['name']),
      picUrl: httpsImageUrl(json['picUrl'] ?? json['coverImgUrl']),
    );
  }
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';

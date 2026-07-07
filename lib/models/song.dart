import 'album.dart';
import 'artist.dart';

/// Which backend a [Song] (and the API call needed to play/lyric it) belongs to.
/// [local] is an on-device file imported by the user (played from a `file://`
/// path, not a network backend).
enum MusicSource { migu, netease, kugou, kuwo, local }

/// A playable track. Built from a Netease cloudsearch/detail row
/// ([Song.fromSearchJson]/[Song.fromDetailJson]) or a Migu search row
/// ([Song.fromMiguJson]). [source] tags which backend owns it; [ref] carries the
/// backend-specific identifiers a Netease int [id] can't express (Migu needs
/// contentId / copyrightId / resourceType / lyricUrl).
class Song {
  final int id;
  final String name;
  final List<Artist> artists;
  final Album? album;

  /// Track duration, parsed from `dt` (milliseconds).
  final Duration duration;

  /// Netease fee flag (0 free, 1 VIP, 4 album-purchase, 8 low-quality free).
  final int fee;

  /// Whether the track is not hard-blocked (`privilege.st >= 0`).
  final bool playable;

  /// Backend this track came from.
  final MusicSource source;

  /// Backend-specific identifiers (Migu: contentId/copyrightId/resourceType/
  /// lyricUrl/cover). Empty for Netease (its int [id] is sufficient).
  final Map<String, String> ref;

  /// Recommend "推荐理由" (e.g. "根据你常听"); null outside daily-recommend.
  final String? reason;

  const Song({
    required this.id,
    required this.name,
    required this.artists,
    this.album,
    required this.duration,
    required this.fee,
    required this.playable,
    this.source = MusicSource.netease,
    this.ref = const <String, String>{},
    this.reason,
  });

  factory Song.fromSearchJson(Map<String, dynamic> json) => Song._parse(json);

  factory Song.fromDetailJson(Map<String, dynamic> json) => Song._parse(json);

  factory Song._parse(Map<String, dynamic> json) {
    return Song(
      id: _int(json['id']),
      name: _str(json['name']),
      artists: Artist.listFromJson(
        (json['ar'] ?? json['artists']) as List<dynamic>?,
      ),
      album: _albumOf(json),
      duration: Duration(milliseconds: _int(json['dt'] ?? json['duration'])),
      fee: _int(json['fee']),
      playable: _playableOf(json),
      reason: (json['reason'] ?? json['recommendReason']) as String?,
    );
  }

  /// Parses a Migu `search_all.do` / `resourceinfo.do` song row. The numeric
  /// `contentId` is parsed into [id] (64-bit on Android — unique per track), so
  /// all the existing int-keyed plumbing (url cache, likes, lyric/extras change
  /// detection) keeps working; the string ids live in [ref].
  factory Song.fromMiguJson(Map<String, dynamic> json) {
    final String contentId = _str(json['contentId']);
    final String copyrightId = _str(json['copyrightId']);
    String resourceType = _str(json['resourceType']);
    if (resourceType.isEmpty) resourceType = '2';

    final int id = int.tryParse(contentId) ??
        int.tryParse(_str(json['id'])) ??
        contentId.hashCode;

    final List<Artist> artists = ((json['singers'] as List<dynamic>?) ??
            const <dynamic>[])
        .whereType<Map>()
        .map((dynamic s) => Artist(
              id: int.tryParse(_str((s as Map)['id'])) ?? 0,
              name: _str(s['name']),
            ))
        .toList();
    if (artists.isEmpty && _str(json['singer']).isNotEmpty) {
      artists.add(Artist(id: 0, name: _str(json['singer'])));
    }

    final String cover = _miguCover(json);
    Album? album;
    final List<dynamic> albums =
        (json['albums'] as List<dynamic>?) ?? const <dynamic>[];
    if (albums.isNotEmpty && albums.first is Map) {
      final Map<String, dynamic> m =
          Map<String, dynamic>.from(albums.first as Map);
      album = Album(
        id: int.tryParse(_str(m['id'])) ?? 0,
        name: _str(m['name']),
        picUrl: cover.isEmpty ? null : cover,
      );
    } else if (cover.isNotEmpty || _str(json['album']).isNotEmpty) {
      album = Album(
        id: int.tryParse(_str(json['albumId'])) ?? 0,
        name: _str(json['album']),
        picUrl: cover.isEmpty ? null : cover,
      );
    }

    final String lyricUrl = _str(json['lyricUrl'] ?? json['lrcUrl']);

    // Strategy (VIP) playback needs songId + albumId; stash them alongside the
    // existing identifiers. songId falls back to the raw id, albumId to the
    // first album's id.
    final String songIdRef = _str(json['songId'] ?? json['id']);
    final dynamic firstAlbumId = (albums.isNotEmpty && albums.first is Map)
        ? (albums.first as Map)['id']
        : null;
    final String albumIdRef = _str(json['albumId'] ?? firstAlbumId);

    return Song(
      id: id,
      name: _str(json['name'] ?? json['songName']),
      artists: artists,
      album: album,
      duration: _miguDuration(json),
      fee: 0,
      playable: true,
      source: MusicSource.migu,
      ref: <String, String>{
        'contentId': contentId,
        'copyrightId': copyrightId,
        'resourceType': resourceType,
        'songId': songIdRef,
        'albumId': albumIdRef,
        if (lyricUrl.isNotEmpty) 'lyricUrl': lyricUrl,
        if (cover.isNotEmpty) 'cover': cover,
      },
    );
  }

  /// Parses a Kugou `complexsearch` song row. Kugou identifies a track by its
  /// `EMixSongID` (fed to the play-url as `encode_album_audio_id`) and its
  /// `FileHash` (used for the lyric lookup and to derive a stable int [id]); both
  /// live in [ref]. [id] is derived from the hash so all the int-keyed plumbing
  /// (url cache, likes, local-playlist rows) keeps working across launches.
  factory Song.fromKugouJson(Map<String, dynamic> json) {
    final String mixId = _str(json['EMixSongID'] ?? json['emixsongid']);
    final String hash = _str(json['FileHash'] ??
            json['SQFileHash'] ??
            json['HQFileHash'] ??
            json['Hash'])
        .toUpperCase();
    final int id = _kugouId(hash, mixId);

    final String title =
        _stripTags(_str(json['SongName'] ?? json['FileName'] ?? json['songname']));
    final String singer = _stripTags(_str(
        json['SingerName'] ?? json['singername'] ?? json['author_name']));
    final String albumName =
        _stripTags(_str(json['AlbumName'] ?? json['album_name']));
    final String cover = _kugouCover(json);

    final List<Artist> artists = <Artist>[];
    for (final String part in singer.split(RegExp(r'[、/&]'))) {
      final String p = part.trim();
      if (p.isNotEmpty) artists.add(Artist(id: 0, name: p));
    }
    if (artists.isEmpty && singer.isNotEmpty) {
      artists.add(Artist(id: 0, name: singer));
    }

    Album? album;
    if (albumName.isNotEmpty || cover.isNotEmpty) {
      album = Album(
        id: int.tryParse(_str(json['AlbumID'] ?? json['album_id'])) ?? 0,
        name: albumName,
        picUrl: cover.isEmpty ? null : cover,
      );
    }

    return Song(
      id: id,
      name: title,
      artists: artists,
      album: album,
      duration:
          Duration(seconds: _int(json['Duration'] ?? json['duration'] ?? json['TimeLength'])),
      fee: 0,
      playable: true,
      source: MusicSource.kugou,
      ref: <String, String>{
        if (mixId.isNotEmpty) 'albumAudioId': mixId,
        if (hash.isNotEmpty) 'hash': hash,
        if (cover.isNotEmpty) 'cover': cover,
      },
    );
  }

  /// Builds a [Song] for a LOCAL on-device audio file. The absolute [path] is
  /// stashed in [ref] (the `local` backend turns it into a `file://` play URL);
  /// the display title/artist come from [title]/[artist] when known, else are
  /// parsed from the filename ("Artist - Title.mp3"). [id] is a stable pure-Dart
  /// hash of the path so a persisted 共同歌单 row keeps matching across launches.
  factory Song.fromLocalFile(
    String path, {
    String? title,
    String? artist,
    Duration duration = Duration.zero,
  }) {
    final String base = _basenameNoExt(path);
    String name = (title ?? '').trim();
    String artistName = (artist ?? '').trim();
    if (name.isEmpty) {
      // "Artist - Title" convention, else the whole basename is the title.
      final int sep = base.indexOf(' - ');
      if (sep > 0 && artistName.isEmpty) {
        artistName = base.substring(0, sep).trim();
        name = base.substring(sep + 3).trim();
      } else {
        name = base;
      }
    }
    if (name.isEmpty) name = base.isEmpty ? '未知音乐' : base;
    return Song(
      id: _localId(path),
      name: name,
      artists: artistName.isEmpty
          ? const <Artist>[]
          : <Artist>[Artist(id: 0, name: artistName)],
      duration: duration,
      fee: 0,
      playable: true,
      source: MusicSource.local,
      ref: <String, String>{'path': path},
    );
  }

  /// "Artist A / Artist B".
  String get artistNames => artists.map((a) => a.name).join(' / ');

  /// Album cover URL (or null).
  String? get artworkUrl => album?.picUrl;

  Song copyWith({bool? playable, String? reason}) => Song(
        id: id,
        name: name,
        artists: artists,
        album: album,
        duration: duration,
        fee: fee,
        playable: playable ?? this.playable,
        source: source,
        ref: ref,
        reason: reason ?? this.reason,
      );

  /// Round-trips a song to/from LOCAL persistence (local playlists, and the
  /// playback session store's shape). Every backend-specific identifier is kept
  /// ([source] + [ref]) so a persisted cross-source ("共同歌单") track can be played
  /// and lyric'd via its own backend after a restart.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'artists': artists
            .map((Artist a) => <String, dynamic>{'id': a.id, 'name': a.name})
            .toList(),
        if (album != null)
          'album': <String, dynamic>{
            'id': album!.id,
            'name': album!.name,
            'picUrl': album!.picUrl,
          },
        'durationMs': duration.inMilliseconds,
        'fee': fee,
        'playable': playable,
        'source': source.name,
        'ref': ref,
        if (reason != null) 'reason': reason,
      };

  /// Rebuilds a [Song] from [toJson]. Unknown/absent source names fall back to
  /// Netease; the [ref] map is restored whole.
  factory Song.fromStoredJson(Map<String, dynamic> j) {
    final List<Artist> artists = <Artist>[];
    final dynamic ar = j['artists'];
    if (ar is List) {
      for (final dynamic e in ar) {
        if (e is Map) {
          final Map<String, dynamic> m = Map<String, dynamic>.from(e);
          artists.add(Artist(id: _int(m['id']), name: _str(m['name'])));
        }
      }
    }

    Album? album;
    final dynamic al = j['album'];
    if (al is Map) {
      final Map<String, dynamic> m = Map<String, dynamic>.from(al);
      final dynamic pic = m['picUrl'];
      album = Album(
        id: _int(m['id']),
        name: _str(m['name']),
        picUrl: pic is String && pic.isNotEmpty ? pic : null,
      );
    }

    final Map<String, String> ref = <String, String>{};
    final dynamic r = j['ref'];
    if (r is Map) {
      r.forEach((dynamic k, dynamic v) => ref[k.toString()] = v?.toString() ?? '');
    }

    MusicSource source = MusicSource.netease;
    final String? sn = j['source']?.toString();
    for (final MusicSource s in MusicSource.values) {
      if (s.name == sn) {
        source = s;
        break;
      }
    }

    return Song(
      id: _int(j['id']),
      name: _str(j['name']),
      artists: artists,
      album: album,
      duration: Duration(milliseconds: _int(j['durationMs'])),
      fee: _int(j['fee']),
      playable: (j['playable'] as bool?) ?? true,
      source: source,
      ref: ref,
      reason: j['reason'] as String?,
    );
  }
}

Album? _albumOf(Map<String, dynamic> json) {
  final dynamic al = json['al'] ?? json['album'];
  if (al is Map) return Album.fromJson(Map<String, dynamic>.from(al));
  return null;
}

bool _playableOf(Map<String, dynamic> json) {
  final dynamic priv = json['privilege'];
  if (priv is Map && priv['st'] != null) {
    return _int(priv['st']) >= 0;
  }
  return true;
}

/// Largest available Migu cover from `imgItems` / `albumImgs` (sizeType 03 > 02
/// > 01). URLs are already HTTPS `.webp`, which Flutter decodes natively.
String _miguCover(Map<String, dynamic> json) {
  final List<dynamic> imgs = (json['imgItems'] ?? json['albumImgs']) as List<dynamic>? ??
      const <dynamic>[];
  String best = '';
  String bestType = '';
  for (final dynamic it in imgs) {
    if (it is! Map) continue;
    final String img = _str(it['img']);
    if (img.isEmpty) continue;
    final String t = _str(it['imgSizeType']);
    if (best.isEmpty || t.compareTo(bestType) > 0) {
      best = img;
      bestType = t;
    }
  }
  return best;
}

/// Migu duration: `length` is "mm:ss" (or seconds); fall back to 0 (the player
/// reads the real duration from the stream anyway).
Duration _miguDuration(Map<String, dynamic> json) {
  final String len = _str(json['length'] ?? json['duration']);
  if (len.isEmpty) return Duration.zero;
  if (len.contains(':')) {
    final List<String> parts = len.split(':');
    int secs = 0;
    for (final String p in parts) {
      secs = secs * 60 + (int.tryParse(p.trim()) ?? 0);
    }
    return Duration(seconds: secs);
  }
  final int n = int.tryParse(len) ?? 0;
  // Heuristic: large values are ms, small are seconds.
  return n > 6000 ? Duration(milliseconds: n) : Duration(seconds: n);
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';

/// Filename without directory or extension, from an absolute path (handles both
/// `/` and `\` separators so it works on Android and Windows).
String _basenameNoExt(String path) {
  int slash = path.lastIndexOf('/');
  final int back = path.lastIndexOf('\\');
  if (back > slash) slash = back;
  String base = slash >= 0 ? path.substring(slash + 1) : path;
  final int dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  return base;
}

/// Stable 48-bit id for a local file path via FNV-1a (pure Dart, deterministic
/// across launches — unlike `String.hashCode`), web-safe (< 2^53) so it slots
/// into the int-keyed local-playlist / url-cache plumbing like the other sources.
int _localId(String path) {
  int hash = 0xcbf29ce484222325; // FNV-1a 64-bit offset basis
  for (final int c in path.codeUnits) {
    hash ^= c;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF; // FNV prime, keep 64-bit
  }
  return hash & 0xFFFFFFFFFFFF; // low 48 bits
}

/// Strips HTML highlight tags (`<em>…</em>`) Kugou wraps around matched terms.
String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]*>'), '').trim();

/// A stable 48-bit int id from a Kugou FileHash (hex) — web-safe (< 2^53) and
/// deterministic across launches, so persisted local-playlist rows keep matching.
/// Falls back to a masked [String.hashCode] when the hash is absent/short.
int _kugouId(String hash, String mixId) {
  if (hash.length >= 12) {
    final int? v = int.tryParse(hash.substring(0, 12), radix: 16);
    if (v != null) return v;
  }
  if (mixId.isNotEmpty) return mixId.hashCode & 0x7fffffffffff;
  return hash.hashCode & 0x7fffffffffff;
}

/// Largest Kugou cover: the `Image` / `sizable_cover` template carries a `{size}`
/// placeholder — fill it with 480 and upgrade to https. Returns '' when absent.
String _kugouCover(Map<String, dynamic> json) {
  String raw = _str(json['Image'] ??
      json['sizable_cover'] ??
      json['cover'] ??
      json['pic'] ??
      json['album_sizable_cover']);
  if (raw.isEmpty) return '';
  raw = raw.replaceAll('{size}', '480');
  if (raw.startsWith('http://')) raw = raw.replaceFirst('http://', 'https://');
  return raw;
}

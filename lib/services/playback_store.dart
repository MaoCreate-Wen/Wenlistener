import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';

/// Immutable snapshot of the player state persisted across launches so the app
/// can restore the last queue / track / position on cold start (always restored
/// **paused** — see [PlaybackStore]).
class PlaybackSession {
  final List<Song> queue;
  final int currentIndex;
  final int positionMs;

  /// Index into [RepeatMode.values] (kept as a bare int so this layer stays
  /// model-only and doesn't depend on the audio service).
  final int repeatIndex;
  final bool shuffle;

  const PlaybackSession({
    required this.queue,
    required this.currentIndex,
    required this.positionMs,
    required this.repeatIndex,
    required this.shuffle,
  });
}

/// Reads/writes the last [PlaybackSession] to `playback_session.json` under the
/// app support dir (same location strategy as `CookieStore`). Writes are atomic
/// (`.tmp` + rename); all IO errors are swallowed with [debugPrint] so a corrupt
/// or missing file never blocks startup.
///
/// [Song] is serialised through its public getters and rebuilt via the public
/// [Song]/[Album]/[Artist] constructors — no model changes. The Migu [Song.ref]
/// map is persisted whole because Migu playback needs it.
class PlaybackStore {
  static const String _fileName = 'playback_session.json';

  /// Bump when the on-disk shape changes; [load] returns null on a mismatch.
  static const int _version = 1;

  Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Returns the persisted session, or null on missing file / parse error /
  /// version mismatch / empty queue.
  Future<PlaybackSession?> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) return null;
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;

      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);
      if (_int(map['version']) != _version) return null;

      final dynamic queueRaw = map['queue'];
      if (queueRaw is! List || queueRaw.isEmpty) return null;
      final List<Song> queue = <Song>[];
      for (final dynamic e in queueRaw) {
        if (e is Map) {
          queue.add(_songFromJson(Map<String, dynamic>.from(e)));
        }
      }
      if (queue.isEmpty) return null;

      int idx = _int(map['currentIndex']);
      if (idx < 0 || idx >= queue.length) idx = 0;

      return PlaybackSession(
        queue: queue,
        currentIndex: idx,
        positionMs: _int(map['positionMs']),
        repeatIndex: _int(map['repeatIndex']).clamp(0, 2),
        shuffle: map['shuffle'] == true,
      );
    } catch (e) {
      debugPrint('PlaybackStore.load failed: $e');
      return null;
    }
  }

  /// Atomically persists [session] (write to `.tmp`, then rename). Swallows IO
  /// errors.
  Future<void> save(PlaybackSession session) async {
    try {
      final File file = await _file();
      final File tmp = File('${file.path}.tmp');
      final Map<String, dynamic> data = <String, dynamic>{
        'version': _version,
        'currentIndex': session.currentIndex,
        'positionMs': session.positionMs,
        'repeatIndex': session.repeatIndex,
        'shuffle': session.shuffle,
        'queue': session.queue.map(_songToJson).toList(),
      };
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('PlaybackStore.save failed: $e');
    }
  }

  // --- (de)serialisation ---------------------------------------------------

  static Map<String, dynamic> _songToJson(Song s) => <String, dynamic>{
        'id': s.id,
        'name': s.name,
        'artists': s.artists
            .map((Artist a) => <String, dynamic>{'id': a.id, 'name': a.name})
            .toList(),
        if (s.album != null)
          'album': <String, dynamic>{
            'id': s.album!.id,
            'name': s.album!.name,
            'picUrl': s.album!.picUrl,
          },
        'durationMs': s.duration.inMilliseconds,
        'fee': s.fee,
        'playable': s.playable,
        'source': s.source.name,
        'ref': s.ref,
        if (s.reason != null) 'reason': s.reason,
      };

  static Song _songFromJson(Map<String, dynamic> j) {
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
      r.forEach((dynamic k, dynamic v) {
        ref[k.toString()] = v?.toString() ?? '';
      });
    }

    final String? sourceName = j['source']?.toString();
    MusicSource source = MusicSource.netease;
    for (final MusicSource s in MusicSource.values) {
      if (s.name == sourceName) {
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

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';

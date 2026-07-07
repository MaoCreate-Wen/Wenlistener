import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/local_playlist.dart';

/// Persists the user's LOCAL "共同歌单" playlists to `local_playlists.json` under
/// the app-support dir (same strategy as `PlaybackStore` / `SettingsStore`).
/// Writes are atomic (`.tmp` + rename); every IO / parse error is swallowed with
/// [debugPrint] so a corrupt or missing file never blocks startup — it just falls
/// back to an empty list.
///
/// **Never blocks the UI on a big list.** Importing a large playlist (e.g. 网易
/// "我喜欢的音乐" with thousands of tracks) used to `jsonEncode` the whole set on the
/// main isolate — seconds of freeze. Now [save] hands the encode to a background
/// isolate ([compute]) and serialises overlapping writes (a save landing while one
/// is in flight is coalesced into the next), so mutating a huge list stays smooth.
class LocalPlaylistStore {
  static const String _fileName = 'local_playlists.json';

  /// Bump when the on-disk shape changes; [load] returns [] on a mismatch.
  static const int _version = 1;

  bool _writing = false;
  List<LocalPlaylist>? _queued;

  Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<List<LocalPlaylist>> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) return <LocalPlaylist>[];
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return <LocalPlaylist>[];
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return <LocalPlaylist>[];
      final Map<String, dynamic> m = Map<String, dynamic>.from(decoded);
      if ((m['version'] as num?)?.toInt() != _version) return <LocalPlaylist>[];
      final dynamic list = m['playlists'];
      if (list is! List) return <LocalPlaylist>[];
      final List<LocalPlaylist> out = <LocalPlaylist>[];
      for (final dynamic e in list) {
        if (e is Map) {
          out.add(LocalPlaylist.fromJson(Map<String, dynamic>.from(e)));
        }
      }
      return out;
    } catch (e) {
      debugPrint('LocalPlaylistStore.load failed: $e');
      return <LocalPlaylist>[];
    }
  }

  /// Persists [playlists]. Coalesces concurrent calls: if a write is already in
  /// flight, the latest snapshot is queued and written next (so a burst of
  /// mutations collapses to at most one extra write), and the heavy `jsonEncode`
  /// runs off the UI isolate.
  Future<void> save(List<LocalPlaylist> playlists) async {
    _queued = playlists;
    if (_writing) return; // an in-flight write will drain _queued
    _writing = true;
    try {
      while (_queued != null) {
        final List<LocalPlaylist> next = _queued!;
        _queued = null;
        await _write(next);
      }
    } finally {
      _writing = false;
    }
  }

  Future<void> _write(List<LocalPlaylist> playlists) async {
    try {
      final File file = await _file();
      // Build the JSON-able tree on the UI isolate (cheap map-building), then hand
      // the actual string serialisation to a background isolate so a huge list
      // never janks the frame.
      final Map<String, dynamic> payload = <String, dynamic>{
        'version': _version,
        'playlists': playlists.map((LocalPlaylist p) => p.toJson()).toList(),
      };
      final String json = await compute(_encodeJson, payload);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('LocalPlaylistStore.save failed: $e');
    }
  }
}

/// Top-level so it can run in the [compute] isolate (closures that capture can't).
String _encodeJson(Map<String, dynamic> data) => jsonEncode(data);

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/play_url.dart';
import '../models/song.dart';

/// The persisted user settings snapshot.
class SettingsData {
  /// The chosen music backend. Default **Netease** (网易云).
  final MusicSource source;

  /// Whether the lyrics-page background reacts to the music (律动). Default on.
  final bool rhythmEnabled;

  /// Preferred playback audio quality. Default 极高 ([AudioLevel.exhigh]).
  final AudioLevel audioQuality;

  const SettingsData({
    required this.source,
    required this.rhythmEnabled,
    this.audioQuality = AudioLevel.exhigh,
  });

  static const SettingsData defaults = SettingsData(
    source: MusicSource.netease,
    rhythmEnabled: true,
    audioQuality: AudioLevel.exhigh,
  );
}

/// Reads/writes [SettingsData] to `settings.json` under the app-support dir (the
/// same strategy as `PlaybackStore` / `CookieStore`). Writes are atomic (`.tmp` +
/// rename); every IO / parse error is swallowed with [debugPrint] so a corrupt or
/// missing file never blocks startup — it just falls back to [SettingsData.defaults]
/// (source = Netease, 律动 on).
class SettingsStore {
  static const String _fileName = 'settings.json';

  Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<SettingsData> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) return SettingsData.defaults;
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return SettingsData.defaults;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return SettingsData.defaults;
      final Map<String, dynamic> m = Map<String, dynamic>.from(decoded);

      MusicSource source = SettingsData.defaults.source;
      final String? sn = m['source']?.toString();
      for (final MusicSource s in MusicSource.values) {
        if (s.name == sn) {
          source = s;
          break;
        }
      }
      final bool rhythm = m['rhythmEnabled'] is bool
          ? m['rhythmEnabled'] as bool
          : SettingsData.defaults.rhythmEnabled;
      AudioLevel quality = SettingsData.defaults.audioQuality;
      final String? qn = m['audioQuality']?.toString();
      for (final AudioLevel l in AudioLevel.values) {
        if (l.name == qn) {
          quality = l;
          break;
        }
      }
      return SettingsData(
          source: source, rhythmEnabled: rhythm, audioQuality: quality);
    } catch (e) {
      debugPrint('SettingsStore.load failed: $e');
      return SettingsData.defaults;
    }
  }

  Future<void> save({
    required MusicSource source,
    required bool rhythmEnabled,
    required AudioLevel audioQuality,
  }) async {
    try {
      final File file = await _file();
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, dynamic>{
          'source': source.name,
          'rhythmEnabled': rhythmEnabled,
          'audioQuality': audioQuality.name,
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('SettingsStore.save failed: $e');
    }
  }
}

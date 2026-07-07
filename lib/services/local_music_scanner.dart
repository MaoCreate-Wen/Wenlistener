import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/song.dart';

/// Picks / scans on-device audio files and turns them into local [Song]s (source
/// [MusicSource.local]). Two entry points, both SAF-backed on Android:
///  - [pickFiles]: the system audio picker, multi-select (most reliable — the
///    picked files are readable without any storage permission).
///  - [scanDirectory]: pick a folder, then recursively find audio files in it
///    (best-effort — works where the folder resolves to a real filesystem path;
///    returns [] if the OS only hands back an unlistable content-URI).
class LocalMusicScanner {
  const LocalMusicScanner();

  static const Set<String> _audioExt = <String>{
    'mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'ape', 'wma',
  };

  /// Opens the system audio picker (multi-select) and returns a [Song] per picked
  /// file. Empty when the user cancels or no path is available.
  Future<List<Song>> pickFiles() async {
    try {
      final FilePickerResult? res = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (res == null) return const <Song>[];
      final List<Song> out = <Song>[];
      for (final PlatformFile f in res.files) {
        final String? path = f.path;
        if (path != null && path.isNotEmpty && _isAudio(path)) {
          out.add(Song.fromLocalFile(path));
        }
      }
      return out;
    } catch (e) {
      debugPrint('LocalMusicScanner.pickFiles failed: $e');
      return const <Song>[];
    }
  }

  /// Lets the user pick a folder, then recursively collects audio files inside it.
  Future<List<Song>> scanDirectory() async {
    try {
      final String? dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null || dir.isEmpty) return const <Song>[];
      final Directory root = Directory(dir);
      if (!await root.exists()) return const <Song>[];
      final List<Song> out = <Song>[];
      await for (final FileSystemEntity e
          in root.list(recursive: true, followLinks: false)) {
        if (e is File && _isAudio(e.path)) {
          out.add(Song.fromLocalFile(e.path));
        }
      }
      // Stable, human order (by name) so a scan reads predictably.
      out.sort((Song a, Song b) => a.name.compareTo(b.name));
      return out;
    } catch (e) {
      // Android scoped storage often hands back an unlistable content-URI → the
      // list() throws; fall back to empty (the UI nudges 选择音乐文件 instead).
      debugPrint('LocalMusicScanner.scanDirectory failed: $e');
      return const <Song>[];
    }
  }

  static bool _isAudio(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return _audioExt.contains(path.substring(dot + 1).toLowerCase());
  }
}

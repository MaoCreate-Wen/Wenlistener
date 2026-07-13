import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha1.dart';

import '../models/lyric_line.dart';
import '../models/song.dart';
import 'dio_factory.dart';

/// Default disk-cache budget (512 MB) and the user-selectable choices shown in
/// the settings 缓存 section. Persisted via `SettingsStore` as a raw byte count
/// so future choices need no migration.
const int kCacheMaxBytesDefault = 512 << 20;
const List<int> kCacheMaxBytesChoices = <int>[
  256 << 20, // 256 MB
  512 << 20, // 512 MB
  1 << 30, // 1 GB
  2 << 30, // 2 GB
];

/// Human label for a byte budget ("256 MB", "1 GB").
String cacheBytesLabel(int bytes) => bytes >= (1 << 30)
    ? '${(bytes / (1 << 30)).toStringAsFixed(bytes % (1 << 30) == 0 ? 0 : 1)} GB'
    : '${bytes ~/ (1 << 20)} MB';

/// Size-capped disk cache for fetched network resources, under
/// `getTemporaryDirectory()/wenlistener_cache/`.
///
/// Caches exactly two resource kinds:
///  * **Cover images** (`img/<sha1(url)>`) — read by [DiskCachedImage].
///  * **Lyrics payloads** (`lyrics/<source>-<songId>.json`) — the parsed
///    [Lyrics] serialized to JSON, read through by `MusicApiRouter.lyric`.
///
/// **Audio streams are deliberately NOT cached** — play URLs are per-request /
/// licensed (they expire and are quality- and account-dependent), so caching
/// the bytes would both violate the resolve flow and go stale immediately.
///
/// Design notes (desktop/Windows):
///  * The old cover path (`cached_network_image` → `flutter_cache_manager`)
///    does work on Windows via its JSON-index fallback, but its size cap does
///    not — the legacy `%TEMP%/libCachedImageData` dir was measured at 4 GB on
///    this machine. This store replaces it with a *bounded* cache: files keyed
///    by sha1(url), file **mtimes as the LRU index** (a read bumps the mtime,
///    eviction deletes oldest-first until under [maxBytes]).
///  * Eviction runs debounced after writes and once shortly after startup.
///  * Every disk failure degrades to the network path (reads) or is swallowed
///    (writes) — the cache can never break image loading or lyrics.
class ResourceCache {
  ResourceCache._();

  /// Process-wide instance. A singleton (mirroring `ArtworkPalette`'s static
  /// memo) because [DiskCachedImage] is constructed from static helpers
  /// (`ArtworkImage.providerFor`) that cannot receive injected services.
  static final ResourceCache instance = ResourceCache._();

  static const String _dirName = 'wenlistener_cache';
  static const String _imgDir = 'img';
  static const String _lyricsDir = 'lyrics';

  /// Byte budget; pushed in from `SettingsProvider` (persisted preference).
  int get maxBytes => _maxBytes;
  int _maxBytes = kCacheMaxBytesDefault;
  set maxBytes(int v) {
    if (v <= 0 || v == _maxBytes) return;
    _maxBytes = v;
    _scheduleEvict(const Duration(milliseconds: 400));
  }

  Future<Directory>? _rootFuture;
  final Map<String, Future<Uint8List>> _inflight = <String, Future<Uint8List>>{};
  Dio? _dio;
  Timer? _evictTimer;

  // Debug-only counters, used to PROVE disk hits (restart → covers load with
  // zero network fetches) during verification; printed per lookup in debug.
  int _hits = 0;
  int _misses = 0;

  Dio get _client => _dio ??= DioFactory.createPlain();

  /// Resolves (and memoizes) the cache root, creating the subdirs, sweeping
  /// the orphaned legacy cache once, and scheduling the startup eviction pass.
  Future<Directory> _root() => _rootFuture ??= _initRoot();

  Future<Directory> _initRoot() async {
    final Directory tmp = await getTemporaryDirectory();
    final Directory root = Directory('${tmp.path}/$_dirName');
    await Directory('${root.path}/$_imgDir').create(recursive: true);
    await Directory('${root.path}/$_lyricsDir').create(recursive: true);
    // One-time sweep of the ORPHANED legacy image cache: before this store the
    // covers went through flutter_cache_manager, whose desktop fallback never
    // enforced its size cap (measured 4 GB of dead .jpgs in
    // %TEMP%/libCachedImageData). Nothing references that dir anymore, so
    // reclaim the disk in the background; errors are irrelevant (it's a cache).
    unawaited(() async {
      try {
        final Directory legacy = Directory('${tmp.path}/libCachedImageData');
        if (await legacy.exists()) await legacy.delete(recursive: true);
      } catch (_) {}
    }());
    // Startup LRU pass — delayed so it never competes with the cold start.
    _scheduleEvict(const Duration(seconds: 8));
    return root;
  }

  // --- images ---------------------------------------------------------------

  /// Bytes for [url]: disk hit (bumps mtime) or a single deduplicated network
  /// download that is then persisted. Network/HTTP failures throw (the image
  /// stream shows its error state, identical to the old provider); disk
  /// failures silently fall back to the network.
  Future<Uint8List> imageBytes(String url, {Map<String, String>? headers}) {
    final Future<Uint8List>? pending = _inflight[url];
    if (pending != null) return pending;
    // NOTE the block body: `() => _inflight.remove(url)` would RETURN the
    // removed future, and whenComplete awaits a returned future — the outer
    // future would wait on itself (deadlock: covers never resolve).
    final Future<Uint8List> f = _imageBytes(url, headers).whenComplete(() {
      _inflight.remove(url);
    });
    _inflight[url] = f;
    return f;
  }

  Future<Uint8List> _imageBytes(String url, Map<String, String>? headers) async {
    File? file;
    try {
      final Directory root = await _root();
      file = File('${root.path}/$_imgDir/${_sha1Hex(url)}');
      if (await file.exists()) {
        final Uint8List bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _touch(file);
          _hits++;
          if (kDebugMode) {
            debugPrint('ResourceCache img HIT #$_hits ${_sha1Hex(url)}');
          }
          return bytes;
        }
      }
    } catch (e) {
      debugPrint('ResourceCache img read failed (falling back to network): $e');
    }
    _misses++;
    if (kDebugMode) debugPrint('ResourceCache img MISS #$_misses $url');
    final Response<List<int>> res = await _client.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes, headers: headers),
    );
    final List<int>? data = res.data;
    if (data == null || data.isEmpty) {
      throw Exception('ResourceCache: empty image response for $url');
    }
    final Uint8List bytes =
        data is Uint8List ? data : Uint8List.fromList(data);
    final File? target = file;
    if (target != null) {
      // Persist off the critical path — decode must not wait on the disk.
      unawaited(() async {
        try {
          await _writeAtomic(target, bytes);
          _scheduleEvict();
        } catch (e) {
          debugPrint('ResourceCache img write failed: $e');
        }
      }());
    }
    return bytes;
  }

  /// Drops the cached file for [url] — called when its bytes failed to decode
  /// (corrupt/partial file, or a non-image 200 body) so the next resolve
  /// re-downloads instead of failing forever. No-op when nothing is cached.
  Future<void> invalidateImage(String url) async {
    try {
      final Directory root = await _root();
      await _deleteQuiet(File('${root.path}/$_imgDir/${_sha1Hex(url)}'));
    } catch (_) {}
  }

  // --- lyrics ---------------------------------------------------------------

  Future<File> _lyricsFile(MusicSource source, int id) async {
    final Directory root = await _root();
    return File('${root.path}/$_lyricsDir/${source.name}-$id.json');
  }

  /// Cached [Lyrics] for a song, or null (miss / corrupt / empty). A hit bumps
  /// the file's mtime (LRU); corrupt or empty payloads are deleted so the
  /// caller re-fetches.
  Future<Lyrics?> readLyrics(MusicSource source, int id) async {
    File? f;
    try {
      f = await _lyricsFile(source, id);
      if (!await f.exists()) return null;
      final dynamic decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map || decoded['v'] != 1) {
        unawaited(_deleteQuiet(f));
        return null;
      }
      final Lyrics lyrics = _lyricsFromJson(decoded.cast<String, dynamic>());
      if (lyrics.lines.isEmpty) {
        unawaited(_deleteQuiet(f));
        return null;
      }
      _touch(f);
      if (kDebugMode) debugPrint('ResourceCache lyric HIT ${source.name}-$id');
      return lyrics;
    } catch (e) {
      debugPrint('ResourceCache.readLyrics failed: $e');
      if (f != null) unawaited(_deleteQuiet(f));
      return null;
    }
  }

  /// Persists a *successful, non-empty* lyrics fetch. Callers must NOT write
  /// empty/failed results — transient failures have to stay retryable and an
  /// instrumental's clean empty is cheap to re-confirm.
  Future<void> writeLyrics(MusicSource source, int id, Lyrics lyrics) async {
    if (lyrics.lines.isEmpty) return;
    try {
      final File f = await _lyricsFile(source, id);
      await _writeAtomic(
        f,
        utf8.encode(jsonEncode(_lyricsToJson(lyrics))),
      );
      _scheduleEvict();
    } catch (e) {
      debugPrint('ResourceCache.writeLyrics failed: $e');
    }
  }

  // --- usage / clearing (settings 缓存 section) -------------------------------

  /// Total bytes currently on disk (async walk; called by the settings page).
  Future<int> totalBytes() async {
    try {
      int total = 0;
      final Directory root = await _root();
      await for (final FileSystemEntity e
          in root.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          total += await e.length();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Deletes every cached file (清空缓存). In-flight downloads simply repopulate.
  Future<void> clear() async {
    try {
      final Directory root = await _root();
      for (final String sub in const <String>[_imgDir, _lyricsDir]) {
        final Directory d = Directory('${root.path}/$sub');
        try {
          if (await d.exists()) await d.delete(recursive: true);
        } catch (e) {
          debugPrint('ResourceCache.clear($sub) failed: $e');
        }
        await d.create(recursive: true);
      }
    } catch (e) {
      debugPrint('ResourceCache.clear failed: $e');
    }
  }

  // --- LRU eviction -----------------------------------------------------------

  /// Debounced trigger — writes are bursty (a playlist page populates dozens of
  /// covers), so coalesce them into one pass shortly after the burst ends.
  void _scheduleEvict([Duration delay = const Duration(seconds: 5)]) {
    _evictTimer?.cancel();
    _evictTimer = Timer(delay, () => unawaited(_evictNow()));
  }

  /// Deletes least-recently-used files (oldest mtime first — reads bump it)
  /// until total size is back under [maxBytes]. Any per-file failure (e.g. a
  /// file locked mid-read on Windows) is skipped; the next pass retries.
  Future<void> _evictNow() async {
    try {
      final Directory root = await _root();
      final List<({File file, int size, DateTime mtime})> entries =
          <({File file, int size, DateTime mtime})>[];
      int total = 0;
      await for (final FileSystemEntity e
          in root.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          final FileStat st = await e.stat();
          entries.add((file: e, size: st.size, mtime: st.modified));
          total += st.size;
        } catch (_) {}
      }
      if (total <= _maxBytes) return;
      entries.sort((a, b) => a.mtime.compareTo(b.mtime));
      for (final ({File file, int size, DateTime mtime}) e in entries) {
        if (total <= _maxBytes) break;
        try {
          await e.file.delete();
          total -= e.size;
        } catch (_) {}
      }
      if (kDebugMode) {
        debugPrint(
            'ResourceCache evicted down to ${(total / (1 << 20)).toStringAsFixed(1)} MB '
            '(cap ${cacheBytesLabel(_maxBytes)})');
      }
    } catch (e) {
      debugPrint('ResourceCache eviction failed: $e');
    }
  }

  // --- helpers ----------------------------------------------------------------

  /// Fire-and-forget mtime bump — the read side of the LRU index.
  void _touch(File f) {
    unawaited(() async {
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}
    }());
  }

  Future<void> _deleteQuiet(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// tmp + rename so readers never observe a half-written file.
  Future<void> _writeAtomic(File target, List<int> bytes) async {
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // Windows rename can fail if the target exists/opened — replace it.
      await _deleteQuiet(target);
      await tmp.rename(target.path);
    }
    // Stamp the mtime through the SAME setter [_touch] uses, so every LRU
    // timestamp comes from one clock. Measured on Windows: with a `TZ` env var
    // that disagrees with the system zone (the dev harness exports
    // TZ=America/Los_Angeles on a UTC+8 machine), `setLastModified(now)` lands
    // a constant 7 h behind the kernel-stamped write mtime — mixing the two
    // clocks made freshly-READ files sort as older than freshly-WRITTEN ones,
    // silently inverting eviction order inside that window. A constant offset
    // on ALL entries is harmless (eviction only compares mtimes to each other,
    // never to the wall clock).
    try {
      await target.setLastModified(DateTime.now());
    } catch (_) {} // best effort — kernel write time is a sane fallback
  }

  static String _sha1Hex(String input) {
    final Uint8List digest =
        SHA1Digest().process(Uint8List.fromList(utf8.encode(input)));
    final StringBuffer sb = StringBuffer();
    for (final int b in digest) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

// --- Lyrics <-> JSON (kept here so the frozen model stays untouched) ----------

Map<String, dynamic> _lyricsToJson(Lyrics l) => <String, dynamic>{
      'v': 1,
      'wbw': l.hasWordByWord,
      'tr': l.hasTranslation,
      'lines': <Map<String, dynamic>>[
        for (final LyricLine line in l.lines)
          <String, dynamic>{
            's': line.start.inMilliseconds,
            'e': line.end.inMilliseconds,
            't': line.text,
            if (line.translation != null) 'tl': line.translation,
            if (line.isBackground) 'bg': true,
            if (line.words.isNotEmpty)
              'w': <Map<String, dynamic>>[
                for (final LyricWord w in line.words)
                  <String, dynamic>{
                    't': w.text,
                    's': w.start.inMilliseconds,
                    'e': w.end.inMilliseconds,
                  },
              ],
          },
      ],
    };

Lyrics _lyricsFromJson(Map<String, dynamic> m) {
  final List<LyricLine> lines = <LyricLine>[
    for (final dynamic raw in (m['lines'] as List<dynamic>))
      _lineFromJson((raw as Map).cast<String, dynamic>()),
  ];
  return Lyrics(
    lines: lines,
    hasWordByWord: m['wbw'] == true,
    hasTranslation: m['tr'] == true,
  );
}

LyricLine _lineFromJson(Map<String, dynamic> m) => LyricLine(
      start: Duration(milliseconds: m['s'] as int),
      end: Duration(milliseconds: m['e'] as int),
      text: m['t'] as String,
      translation: m['tl'] as String?,
      isBackground: m['bg'] == true,
      words: <LyricWord>[
        if (m['w'] is List)
          for (final dynamic raw in m['w'] as List<dynamic>)
            LyricWord(
              text: (raw as Map)['t'] as String,
              start: Duration(milliseconds: raw['s'] as int),
              end: Duration(milliseconds: raw['e'] as int),
            ),
      ],
    );

// --- ImageProvider -------------------------------------------------------------

/// Drop-in replacement for `CachedNetworkImageProvider`, backed by
/// [ResourceCache] (bounded, mtime-LRU) instead of `flutter_cache_manager`
/// (whose desktop size cap never fires — see [ResourceCache]).
///
/// Equality is `(url, scale)` — headers excluded — EXACTLY like the provider it
/// replaces, so the in-memory `imageCache` keying is unchanged: every call site
/// wraps this in the same `ResizeImage.resizeIfNeeded(...)` it always used
/// (`ArtworkImage.providerFor`'s `cachePxFor` bucketing, the 128²
/// palette/mesh analysis pair), and equal construction ⇒ equal key ⇒ one
/// decode, preserving the hero-flight precache and the memory plateau.
@immutable
class DiskCachedImage extends ImageProvider<DiskCachedImage> {
  const DiskCachedImage(this.url, {this.scale = 1.0, this.headers});

  final String url;
  final double scale;

  /// Sent on the network fetch only (kNeteaseImageHeaders — the CDN 403s
  /// without a browser UA + Referer). Not part of the cache key.
  final Map<String, String>? headers;

  @override
  Future<DiskCachedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<DiskCachedImage>(this);

  @override
  ImageStreamCompleter loadImage(
          DiskCachedImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _loadAsync(key, decode),
        scale: key.scale,
        debugLabel: key.url,
        informationCollector: () => <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<DiskCachedImage>('Image key', key),
        ],
      );

  Future<ui.Codec> _loadAsync(
      DiskCachedImage key, ImageDecoderCallback decode) async {
    try {
      final Uint8List bytes =
          await ResourceCache.instance.imageBytes(key.url, headers: key.headers);
      final ui.ImmutableBuffer buffer =
          await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(buffer);
    } catch (e) {
      // Failed loads must not poison either cache: drop the (possibly corrupt /
      // non-image) disk entry and evict the in-memory key so a later rebuild
      // retries from scratch — the same recovery NetworkImage performs.
      unawaited(ResourceCache.instance.invalidateImage(key.url));
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is DiskCachedImage && other.url == url && other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'DiskCachedImage')}("$url", scale: $scale)';
}

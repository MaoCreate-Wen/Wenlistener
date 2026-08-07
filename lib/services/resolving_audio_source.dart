import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';

/// A just_audio source whose URL is resolved lazily (on the first byte request)
/// via [resolve], then byte-proxied with HTTP range support so the player can
/// seek. Carries the background [MediaItem] [tag] so the notification renders
/// title/art/controls. Resolving at play time (not queue-build time) keeps
/// playback start instant and avoids time-limited URLs expiring before they're
/// reached. Throwing from [request] makes just_audio error this queue index,
/// which the AudioService treats as "skip to the next playable track".
///
/// The resolved URL is cached so the many range/seek requests of one playthrough
/// reuse it — but the cache **self-heals**: a Migu/Netease link is time-limited,
/// so under [LoopMode.all] a wrap back to this track minutes later can hit an
/// expired URL. A non-success response (or a thrown request) drops the cache,
/// re-resolves **once**, and retries with a fresh URL; only a second failure
/// propagates (the genuinely-unplayable case AudioService skips).
class ResolvingAudioSource extends StreamAudioSource {
  ResolvingAudioSource({
    required this.song,
    required this.resolve,
    required super.tag,
  });

  final Song song;
  final Future<String?> Function(Song) resolve;
  String? _url;

  // One shared, connection-pooling client for every source — avoids spinning up
  // (and leaking) a fresh HttpClient on every range/seek request.
  //
  // `connectionTimeout` caps the TCP connect; without it a dead host would hang
  // the connect forever. But the connect timeout does NOT cover a socket that
  // connects yet never sends response headers (a half-open CDN / captive proxy),
  // so [_fetch] additionally `.timeout()`s the header phase below — otherwise
  // that await never returns, the track stays buffering forever and the
  // auto-skip-to-next chain (which relies on [request] throwing) deadlocks.
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// Deadline for getting response headers back after the request is sent —
  /// guards against a connected-but-silent socket (see [_client]).
  static const Duration _headerTimeout = Duration(seconds: 20);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // Resolve the play URL once and cache it: normal playback fires many
    // range/seek requests that must all reuse the same URL.
    final String? cached = _url ??= await resolve(song);
    if (cached == null) {
      throw Exception('ResolvingAudioSource: no play URL for "${song.name}"');
    }
    try {
      return await _fetch(cached, start, end);
    } catch (e) {
      // The cached URL failed — expired link (403/404/410), an unfollowed
      // redirect, or a socket error after a repeat-all wrap reached this track.
      // Self-heal: drop the cache, re-resolve once, and retry below. A second
      // failure propagates so AudioService skips this (unplayable) index.
      debugPrint(
          'ResolvingAudioSource: stale URL for "${song.name}" ($e); refreshing');
      _url = null;
    }
    final String? fresh = _url = await resolve(song);
    if (fresh == null) {
      throw Exception('ResolvingAudioSource: no play URL for "${song.name}"');
    }
    return _fetch(fresh, start, end);
  }

  /// Opens [url] (with the optional byte range) and adapts the HTTP response to
  /// a [StreamAudioResponse]. Throws on any status outside 200/206 — a stale or
  /// expired link — so [request] can refresh (or, on the retry, AudioService can
  /// skip the index).
  Future<StreamAudioResponse> _fetch(String url, int? start, int? end) async {
    // Local imported music: a `file://` URL is read straight off disk (with byte
    // ranges for seeking) instead of via HTTP — the network proxy below is for
    // the streaming backends.
    if (url.startsWith('file://')) {
      return _fetchFile(Uri.parse(url).toFilePath(), start, end);
    }
    final HttpClientRequest req = await _client
        .getUrl(Uri.parse(url))
        .timeout(_headerTimeout);
    req.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile');
    if (start != null || end != null) {
      req.headers.set(HttpHeaders.rangeHeader,
          'bytes=${start ?? 0}-${end != null ? end - 1 : ''}');
    }
    // Cap the "sent request, waiting for headers" phase: a socket that connects
    // but never replies would otherwise hang here forever. On timeout this throws
    // TimeoutException → request()'s self-heal re-resolves once, then a second
    // failure propagates so AudioService skips this index (never a stuck buffer).
    final HttpClientResponse resp = await req.close().timeout(_headerTimeout);
    final int code = resp.statusCode;
    // Only 200 (full body) and 206 (range) are usable. Anything else — expired
    // CDN link (403/404/410), an unfollowed redirect, 416, … — is a failure:
    // drain the socket back to the shared client's pool, then throw so the
    // caller can re-resolve/skip.
    if (code != HttpStatus.ok && code != HttpStatus.partialContent) {
      unawaited(resp.drain<void>().catchError((_) {}));
      throw HttpException('unexpected status $code', uri: Uri.tryParse(url));
    }
    final bool partial = code == HttpStatus.partialContent;
    int? sourceLength;
    if (partial) {
      final String? cr = _firstHeader(resp.headers, HttpHeaders.contentRangeHeader);
      if (cr != null && cr.contains('/')) {
        sourceLength = int.tryParse(cr.split('/').last.trim());
      }
    } else {
      sourceLength = resp.contentLength >= 0 ? resp.contentLength : null;
    }
    return StreamAudioResponse(
      rangeRequestsSupported: partial ||
          _firstHeader(resp.headers, HttpHeaders.acceptRangesHeader) == 'bytes',
      sourceLength: sourceLength,
      contentLength: resp.contentLength >= 0 ? resp.contentLength : null,
      offset: start ?? 0,
      stream: resp, // HttpClientResponse is a Stream<List<int>>
      contentType: resp.headers.contentType?.mimeType ?? 'audio/mpeg',
    );
  }

  /// Serves a local file [path] with byte-range support (so the player can seek)
  /// straight from disk — the local-music counterpart to [_fetch]'s HTTP path.
  Future<StreamAudioResponse> _fetchFile(
      String path, int? start, int? end) async {
    final File file = File(path);
    final int length = await file.length();
    final int from = start ?? 0;
    final int to = end ?? length; // openRead's `end` is exclusive
    return StreamAudioResponse(
      rangeRequestsSupported: true,
      sourceLength: length,
      contentLength: to - from,
      offset: from,
      stream: file.openRead(from, to),
      contentType: _mimeForPath(path),
    );
  }

  /// Reads a single header value WITHOUT throwing when the server sent it more
  /// than once. `HttpHeaders.value()` throws `HttpException: More than one value
  /// for header …` on duplicates — some CDNs (e.g. Kugou 概念版's fs.youthandroid)
  /// return `accept-ranges` twice, which otherwise crashed every fetch → the track
  /// looped on "Source error". Take the first value instead.
  static String? _firstHeader(HttpHeaders headers, String name) {
    final List<String>? v = headers[name];
    return (v != null && v.isNotEmpty) ? v.first : null;
  }

  static String _mimeForPath(String path) {
    final String p = path.toLowerCase();
    if (p.endsWith('.flac')) return 'audio/flac';
    if (p.endsWith('.m4a') || p.endsWith('.aac')) return 'audio/mp4';
    if (p.endsWith('.wav')) return 'audio/wav';
    if (p.endsWith('.ogg') || p.endsWith('.opus')) return 'audio/ogg';
    return 'audio/mpeg'; // .mp3 and unknown
  }
}

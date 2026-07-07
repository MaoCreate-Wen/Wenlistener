import 'song.dart';

/// Where a [LocalPlaylist] was forked from — a backend (网易/咪咕) playlist. Lets a
/// local list be RE-SYNCED against its remote source later: [LocalPlaylistProvider]
/// diffs the remote's current tracks against [LocalPlaylist.syncedIds] and only
/// adds/removes the delta, so previously-arranged tracks (and hand-added ones from
/// OTHER sources, e.g. 酷狗) keep their position. Null for a hand-built list.
class LocalPlaylistOrigin {
  /// Backend the source playlist lives on (its [MusicApi] is used for re-sync).
  final MusicSource source;

  /// The backend playlist id (int — Netease/Migu). Fed to `playlistDetail`.
  final int remoteId;

  /// The source playlist's name at import time (shown as "来自…" on the detail).
  final String remoteName;

  const LocalPlaylistOrigin({
    required this.source,
    required this.remoteId,
    required this.remoteName,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source.name,
        'remoteId': remoteId,
        'remoteName': remoteName,
      };

  static LocalPlaylistOrigin? fromJson(dynamic j) {
    if (j is! Map) return null;
    final Map<String, dynamic> m = Map<String, dynamic>.from(j);
    MusicSource source = MusicSource.netease;
    final String? sn = m['source']?.toString();
    for (final MusicSource s in MusicSource.values) {
      if (s.name == sn) {
        source = s;
        break;
      }
    }
    return LocalPlaylistOrigin(
      source: source,
      remoteId: _int(m['remoteId']),
      remoteName: (m['remoteName'] ?? '').toString(),
    );
  }
}

/// A LOCAL, cross-source playlist — the "共同歌单" feature. Unlike a [Playlist]
/// (which mirrors a Netease/Migu server list keyed by an int id), this lives only
/// on-device and can hold [Song]s from ANY backend (网易 / 咪咕 / 酷狗) in one list.
/// Each track keeps its own [Song.source] / [Song.ref], so the router plays and
/// fetches lyrics for it per-song — that's what lets a Netease-imported list take
/// a Kugou track and still play end to end, with no official playlist API.
class LocalPlaylist {
  /// Opaque local id (a `lp_…` string, never an int) so it can't collide with a
  /// backend playlist id anywhere in the app.
  final String id;
  final String name;
  final List<Song> tracks;
  final int createdAt; // ms epoch
  final int updatedAt; // ms epoch

  /// The backend playlist this list was imported from, or null for a hand-built
  /// list. Present ⇒ the list is RE-SYNCABLE (see [syncedIds]).
  final LocalPlaylistOrigin? origin;

  /// Snapshot of the remote track ids as of the LAST sync (import counts as the
  /// first sync). The re-sync comparator uses it to tell REMOTE-owned tracks —
  /// which may be removed when they disappear upstream — apart from tracks the
  /// user hand-added from another source, which are NEVER auto-removed. Empty for
  /// a hand-built list.
  final List<int> syncedIds;

  const LocalPlaylist({
    required this.id,
    required this.name,
    this.tracks = const <Song>[],
    required this.createdAt,
    required this.updatedAt,
    this.origin,
    this.syncedIds = const <int>[],
  });

  int get trackCount => tracks.length;

  /// Whether this list can be re-synced against a backend playlist.
  bool get isSyncable => origin != null;

  /// Cover art = the first track that has one (a local list has no cover of its
  /// own). Null when every track lacks artwork / the list is empty.
  String? get coverUrl {
    for (final Song s in tracks) {
      final String? u = s.artworkUrl;
      if (u != null && u.isNotEmpty) return u;
    }
    return null;
  }

  bool contains(int songId) => tracks.any((Song s) => s.id == songId);

  LocalPlaylist copyWith({
    String? name,
    List<Song>? tracks,
    int? updatedAt,
    LocalPlaylistOrigin? origin,
    List<int>? syncedIds,
  }) =>
      LocalPlaylist(
        id: id,
        name: name ?? this.name,
        tracks: tracks ?? this.tracks,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        origin: origin ?? this.origin,
        syncedIds: syncedIds ?? this.syncedIds,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'tracks': tracks.map((Song s) => s.toJson()).toList(),
        if (origin != null) 'origin': origin!.toJson(),
        if (syncedIds.isNotEmpty) 'syncedIds': syncedIds,
      };

  factory LocalPlaylist.fromJson(Map<String, dynamic> j) {
    final List<Song> tracks = <Song>[];
    final dynamic raw = j['tracks'];
    if (raw is List) {
      for (final dynamic e in raw) {
        if (e is Map) {
          tracks.add(Song.fromStoredJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    final List<int> synced = <int>[];
    final dynamic si = j['syncedIds'];
    if (si is List) {
      for (final dynamic e in si) {
        synced.add(_int(e));
      }
    }
    return LocalPlaylist(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      tracks: tracks,
      createdAt: _int(j['createdAt']),
      updatedAt: _int(j['updatedAt']),
      origin: LocalPlaylistOrigin.fromJson(j['origin']),
      syncedIds: synced,
    );
  }
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

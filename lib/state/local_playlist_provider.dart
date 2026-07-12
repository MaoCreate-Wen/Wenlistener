import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/local_playlist.dart';
import '../models/song.dart';
import '../services/local_music_scanner.dart';
import '../services/local_playlist_store.dart';

/// Owns the user's LOCAL "共同歌单" — cross-source playlists that hold songs from
/// ANY backend (网易 / 咪咕 / 酷狗) in one list, persisted on-device via
/// [LocalPlaylistStore] (no official playlist API involved). Each song keeps its
/// own [Song.source] / [Song.ref], so `MusicApiRouter` plays / lyrics it per-song
/// — a Netease-imported list can take a Kugou track and still play end to end.
///
/// Mutations are copy-on-write (new [LocalPlaylist] instances) so `context.select`
/// on a single playlist rebuilds only when THAT list changes, then persisted.
class LocalPlaylistProvider extends ChangeNotifier {
  final LocalPlaylistStore store;

  /// Picks/scans on-device audio files for the "导入本地音乐" flow. Optional so unit
  /// tests can construct the provider without the file-picker plugin.
  final LocalMusicScanner? scanner;

  LocalPlaylistProvider({required this.store, this.scanner}) {
    unawaited(_init());
  }

  List<LocalPlaylist> _playlists = <LocalPlaylist>[];
  bool _loaded = false;
  final Random _rng = Random();

  /// All local playlists, newest first.
  List<LocalPlaylist> get playlists => _playlists;

  /// Whether the on-disk list has been read (false only for the first frame or two
  /// after launch).
  bool get loaded => _loaded;

  LocalPlaylist? byId(String id) {
    for (final LocalPlaylist p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Whether [songId] is already in the playlist [id] (drives the ✓/＋ affordance).
  bool containsSong(String id, int songId) => byId(id)?.contains(songId) ?? false;

  Future<void> _init() async {
    _playlists = await store.load();
    _loaded = true;
    notifyListeners();
  }

  String _newId() =>
      'lp_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '_${_rng.nextInt(1 << 32).toRadixString(36)}';

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// Creates a playlist (optionally pre-filled by importing [tracks] — the
  /// "导入到本地歌单" flow) and returns it. Inserted newest-first.
  ///
  /// Pass [origin] when the list is forked from a backend playlist: it records
  /// where to re-sync from, and the imported [tracks] become the initial
  /// [LocalPlaylist.syncedIds] baseline the comparator diffs against later.
  Future<LocalPlaylist> create(
    String name, {
    List<Song> tracks = const <Song>[],
    LocalPlaylistOrigin? origin,
  }) async {
    final int ts = _now();
    final String trimmed = name.trim();
    final LocalPlaylist pl = LocalPlaylist(
      id: _newId(),
      name: trimmed.isEmpty ? '新建歌单' : trimmed,
      tracks: List<Song>.of(tracks),
      createdAt: ts,
      updatedAt: ts,
      origin: origin,
      // The imported tracks are the first sync snapshot (only for a remote fork;
      // a hand-built list has no remote baseline, so nothing is auto-removable).
      syncedIds: origin == null
          ? const <int>[]
          : tracks.map((Song s) => s.id).toList(),
    );
    _playlists = <LocalPlaylist>[pl, ..._playlists];
    notifyListeners();
    await _persist();
    return pl;
  }

  /// Re-syncs the local list [id] against its remote source's CURRENT [remoteTracks]
  /// — the "新增歌曲比较器" that powers 多音源歌单共同管理.
  ///
  /// Instead of rebuilding the list (which would lose the user's arrangement and
  /// any hand-added cross-source tracks), it diffs against [LocalPlaylist.syncedIds]
  /// and applies only the delta:
  ///  - a track that WAS synced but is gone upstream is removed;
  ///  - a hand-added track (never in the synced snapshot) is always kept;
  ///  - surviving tracks keep their existing ORDER;
  ///  - genuinely-new remote tracks are inserted at the TOP (newest-first, in
  ///    remote order) — so a re-sync surfaces new songs immediately.
  ///
  /// Returns `(added, removed)` counts for a confirmation. No-op (0,0) when the
  /// list is missing or isn't a remote fork.
  Future<({int added, int removed})> resync(
    String id,
    List<Song> remoteTracks,
  ) async {
    final LocalPlaylist? pl = byId(id);
    if (pl == null || !pl.isSyncable) return (added: 0, removed: 0);

    final List<int> remoteIds =
        remoteTracks.map((Song s) => s.id).toList(growable: false);
    final Set<int> remoteSet = remoteIds.toSet();
    final Set<int> syncedSet = pl.syncedIds.toSet();

    // Keep everything except tracks that were synced before and are now gone
    // upstream — order preserved. Hand-added tracks (not in syncedSet) survive.
    final List<Song> survivors = <Song>[];
    int removed = 0;
    for (final Song t in pl.tracks) {
      final bool wasSynced = syncedSet.contains(t.id);
      if (wasSynced && !remoteSet.contains(t.id)) {
        removed++;
        continue;
      }
      survivors.add(t);
    }

    // Brand-new upstream tracks (not already present) go to the TOP, in remote
    // order; the surviving tracks keep their relative order below.
    final Set<int> present = survivors.map((Song s) => s.id).toSet();
    final List<Song> additions = <Song>[];
    for (final Song t in remoteTracks) {
      if (present.add(t.id)) additions.add(t);
    }
    final int added = additions.length;

    if (added == 0 && removed == 0) {
      // Nothing changed, but refresh the synced snapshot in case upstream merely
      // reordered — cheap, and keeps the baseline exact.
      await _mutate(id, (LocalPlaylist p) => p.copyWith(syncedIds: remoteIds));
      return (added: 0, removed: 0);
    }

    await _mutate(
      id,
      (LocalPlaylist p) => p.copyWith(
        tracks: <Song>[...additions, ...survivors],
        syncedIds: remoteIds,
        updatedAt: _now(),
      ),
    );
    return (added: added, removed: removed);
  }

  Future<void> rename(String id, String name) => _mutate(
        id,
        (LocalPlaylist p) =>
            p.copyWith(name: name.trim(), updatedAt: _now()),
      );

  Future<void> delete(String id) async {
    final int before = _playlists.length;
    _playlists = _playlists.where((LocalPlaylist p) => p.id != id).toList();
    if (_playlists.length != before) {
      notifyListeners();
      await _persist();
    }
  }

  /// Inserts [song] at the TOP (newest-first — the just-added track should be
  /// visible immediately, not buried at the bottom) unless a track with the same
  /// [Song.id] is already present. Returns whether it was added.
  Future<bool> addSong(String id, Song song) async {
    final LocalPlaylist? pl = byId(id);
    if (pl == null || pl.contains(song.id)) return false;
    await _mutate(
      id,
      (LocalPlaylist p) => p.copyWith(
        tracks: <Song>[song, ...p.tracks],
        updatedAt: _now(),
      ),
    );
    return true;
  }

  /// "导入本地音乐": picks on-device audio files (or scans a folder when [scanDir])
  /// and inserts the new ones at the TOP of the local playlist [id] (newest-first,
  /// like [addSong]). Dedups by [Song.id] (against the list AND within the batch),
  /// then persists in ONE write. Returns the number of tracks actually added.
  Future<int> importLocalFiles(String id, {bool scanDir = false}) async {
    final LocalMusicScanner? sc = scanner;
    final LocalPlaylist? pl = byId(id);
    if (sc == null || pl == null) return 0;
    final List<Song> songs =
        scanDir ? await sc.scanDirectory() : await sc.pickFiles();
    if (songs.isEmpty) return 0;
    final Set<int> seen = pl.tracks.map((Song s) => s.id).toSet();
    final List<Song> toAdd = <Song>[];
    for (final Song s in songs) {
      if (seen.add(s.id)) toAdd.add(s);
    }
    if (toAdd.isEmpty) return 0;
    await _mutate(
      id,
      (LocalPlaylist p) => p.copyWith(
        tracks: <Song>[...toAdd, ...p.tracks],
        updatedAt: _now(),
      ),
    );
    return toAdd.length;
  }

  /// "从本地音乐新建歌单": picks/scans on-device audio files into a NEW local
  /// playlist named [name]. Returns the created playlist, or null when there's no
  /// scanner or nothing was picked.
  Future<LocalPlaylist?> createFromLocalFiles(
    String name, {
    bool scanDir = false,
  }) async {
    final LocalMusicScanner? sc = scanner;
    if (sc == null) return null;
    final List<Song> songs =
        scanDir ? await sc.scanDirectory() : await sc.pickFiles();
    if (songs.isEmpty) return null;
    // Dedup within the picked batch (a folder scan can surface the same file via
    // multiple links); keeps the created list clean.
    final Set<int> seen = <int>{};
    final List<Song> unique =
        songs.where((Song s) => seen.add(s.id)).toList();
    return create(name, tracks: unique);
  }

  Future<void> removeSong(String id, int songId) => _mutate(
        id,
        (LocalPlaylist p) => p.copyWith(
          tracks: p.tracks.where((Song s) => s.id != songId).toList(),
          updatedAt: _now(),
        ),
      );

  /// Applies [f] to the playlist [id] (copy-on-write), notifies and persists.
  Future<void> _mutate(
    String id,
    LocalPlaylist Function(LocalPlaylist) f,
  ) async {
    bool changed = false;
    _playlists = _playlists.map((LocalPlaylist p) {
      if (p.id != id) return p;
      changed = true;
      return f(p);
    }).toList();
    if (changed) {
      notifyListeners();
      await _persist();
    }
  }

  Future<void> _persist() => store.save(_playlists);
}

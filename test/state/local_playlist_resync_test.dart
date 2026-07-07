import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/models/artist.dart';
import 'package:wenlistener/models/local_playlist.dart';
import 'package:wenlistener/models/song.dart';
import 'package:wenlistener/services/local_playlist_store.dart';
import 'package:wenlistener/state/local_playlist_provider.dart';

/// In-memory [LocalPlaylistStore] — no disk / path_provider in unit tests.
class _MemStore extends LocalPlaylistStore {
  List<LocalPlaylist> saved = <LocalPlaylist>[];

  @override
  Future<List<LocalPlaylist>> load() async => <LocalPlaylist>[];

  @override
  Future<void> save(List<LocalPlaylist> playlists) async {
    saved = List<LocalPlaylist>.of(playlists);
  }
}

Song _song(int id, {MusicSource source = MusicSource.netease, String? name}) =>
    Song(
      id: id,
      name: name ?? 'Song $id',
      artists: <Artist>[Artist(id: 0, name: 'A')],
      duration: const Duration(seconds: 100),
      fee: 0,
      playable: true,
      source: source,
    );

List<int> _ids(LocalPlaylist p) => p.tracks.map((Song s) => s.id).toList();

void main() {
  group('LocalPlaylistProvider.resync (新增歌曲比较器)', () {
    late LocalPlaylistProvider provider;

    setUp(() async {
      provider = LocalPlaylistProvider(store: _MemStore());
      // Let the constructor's _init() (empty load) settle.
      await Future<void>.delayed(Duration.zero);
    });

    test('keeps existing order, appends new remote tracks, drops removed ones, '
        'and never touches hand-added cross-source tracks', () async {
      // Import a Netease playlist [1,2,3].
      final LocalPlaylist pl = await provider.create(
        'L',
        tracks: <Song>[_song(1), _song(2), _song(3)],
        origin: const LocalPlaylistOrigin(
          source: MusicSource.netease,
          remoteId: 42,
          remoteName: 'src',
        ),
      );
      // Hand-add a Kugou track (id 100) — NOT part of the synced snapshot.
      // addSong inserts at the TOP (newest-first), so 100 lands at the front.
      await provider.addSong(pl.id, _song(100, source: MusicSource.kugou));
      expect(_ids(provider.byId(pl.id)!), <int>[100, 1, 2, 3]);

      // Upstream now: [1, 3, 4] — song 2 removed, song 4 added, order [1 then 3].
      final ({int added, int removed}) diff = await provider.resync(
        pl.id,
        <Song>[_song(1), _song(3), _song(4)],
      );

      expect(diff.added, 1);
      expect(diff.removed, 1);
      // New remote track 4 goes to the TOP; survivors [100, 1, 3] keep their order.
      expect(_ids(provider.byId(pl.id)!), <int>[4, 100, 1, 3]);
      // The synced baseline is now exactly the remote snapshot.
      expect(provider.byId(pl.id)!.syncedIds, <int>[1, 3, 4]);
    });

    test('is stable — a second sync with identical remote is a no-op', () async {
      final LocalPlaylist pl = await provider.create(
        'L',
        tracks: <Song>[_song(1), _song(2)],
        origin: const LocalPlaylistOrigin(
          source: MusicSource.netease,
          remoteId: 1,
          remoteName: 'src',
        ),
      );
      await provider.addSong(pl.id, _song(200, source: MusicSource.kugou));

      final remote = <Song>[_song(1), _song(2)];
      final d1 = await provider.resync(pl.id, remote);
      expect(d1, (added: 0, removed: 0));
      final List<int> after1 = _ids(provider.byId(pl.id)!);

      final d2 = await provider.resync(pl.id, remote);
      expect(d2, (added: 0, removed: 0));
      expect(_ids(provider.byId(pl.id)!), after1); // order unchanged across syncs
      // 200 was hand-added at the TOP (newest-first insert); syncs never move it.
      expect(after1, <int>[200, 1, 2]);
    });

    test('a hand-built list (no origin) is not syncable → resync is a no-op',
        () async {
      final LocalPlaylist pl =
          await provider.create('manual', tracks: <Song>[_song(1)]);
      expect(pl.isSyncable, isFalse);
      final d = await provider.resync(pl.id, <Song>[_song(1), _song(2)]);
      expect(d, (added: 0, removed: 0));
      expect(_ids(provider.byId(pl.id)!), <int>[1]); // untouched
    });

    test('origin + syncedIds round-trip through JSON', () async {
      final LocalPlaylist pl = await provider.create(
        'L',
        tracks: <Song>[_song(1), _song(2)],
        origin: const LocalPlaylistOrigin(
          source: MusicSource.migu,
          remoteId: 7,
          remoteName: 'migu list',
        ),
      );
      final LocalPlaylist restored =
          LocalPlaylist.fromJson(pl.toJson());
      expect(restored.origin?.source, MusicSource.migu);
      expect(restored.origin?.remoteId, 7);
      expect(restored.origin?.remoteName, 'migu list');
      expect(restored.syncedIds, <int>[1, 2]);
      expect(restored.isSyncable, isTrue);
    });
  });
}

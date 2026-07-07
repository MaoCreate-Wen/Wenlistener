import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/models/artist.dart';
import 'package:wenlistener/models/playlist.dart';
import 'package:wenlistener/models/song.dart';
import 'package:wenlistener/services/migu_api.dart';

/// Hermetic (offline) unit checks for the daily-recommend widening and the
/// additive model fields owned by the backend API layer. No network is touched:
/// the Migu daily-recommend overrides are pure stubs, and the model checks are
/// constructed in-memory.
void main() {
  group('MiguApi daily-recommend stubs', () {
    test('return const [] without throwing (default + custom limit)', () async {
      final MiguApi api = MiguApi();
      expect(await api.dailyRecommendSongs(), isEmpty);
      expect(await api.dailyRecommendPlaylists(), isEmpty);
      expect(await api.dailyRecommendSongs(limit: 5), isEmpty);
      expect(await api.dailyRecommendPlaylists(limit: 5), isEmpty);
    });
  });

  group('Song.reason (additive)', () {
    test('fromDetailJson reads reason / recommendReason / null', () {
      final Song a = Song.fromDetailJson(<String, dynamic>{
        'id': 1,
        'name': 'x',
        'ar': <dynamic>[],
        'dt': 1000,
        'reason': '根据你常听',
      });
      expect(a.reason, '根据你常听');

      final Song b = Song.fromDetailJson(<String, dynamic>{
        'id': 2,
        'name': 'y',
        'ar': <dynamic>[],
        'dt': 1000,
        'recommendReason': '听歌偏好',
      });
      expect(b.reason, '听歌偏好');

      final Song c = Song.fromDetailJson(<String, dynamic>{
        'id': 3,
        'name': 'z',
        'ar': <dynamic>[],
        'dt': 1000,
      });
      expect(c.reason, isNull);
    });

    test('copyWith carries reason and still honours playable', () {
      const Song s = Song(
        id: 1,
        name: 'x',
        artists: <Artist>[],
        duration: Duration.zero,
        fee: 0,
        playable: true,
      );
      final Song withReason = s.copyWith(reason: '猜你喜欢');
      expect(withReason.reason, '猜你喜欢');
      expect(withReason.playable, isTrue);

      // Existing param keeps working; reason carries through when not overridden.
      final Song blocked = withReason.copyWith(playable: false);
      expect(blocked.playable, isFalse);
      expect(blocked.reason, '猜你喜欢');

      // Untouched reason stays null.
      expect(s.copyWith(playable: false).reason, isNull);
    });
  });

  group('Song.fromMiguJson ref ids (additive)', () {
    test('populates songId + albumId from explicit fields', () {
      final Song s = Song.fromMiguJson(<String, dynamic>{
        'name': '夜曲',
        'contentId': '600902000009524270',
        'copyrightId': '6005572ONWX',
        'resourceType': '2',
        'songId': '1234567',
        'singers': <dynamic>[
          <String, dynamic>{'id': '1', 'name': '周杰伦'},
        ],
        'albums': <dynamic>[
          <String, dynamic>{'id': '1000012211', 'name': '十一月的萧邦'},
        ],
      });
      expect(s.source, MusicSource.migu);
      expect(s.ref['songId'], '1234567');
      expect(s.ref['albumId'], '1000012211');
      // Existing ref keys remain intact.
      expect(s.ref['contentId'], '600902000009524270');
      expect(s.ref['copyrightId'], '6005572ONWX');
      expect(s.ref['resourceType'], '2');
    });

    test('songId falls back to id; albumId falls back to albums[0].id', () {
      final Song s = Song.fromMiguJson(<String, dynamic>{
        'name': 't',
        'contentId': '111',
        'id': '999',
        'albums': <dynamic>[
          <String, dynamic>{'id': '222'},
        ],
      });
      expect(s.ref['songId'], '999');
      expect(s.ref['albumId'], '222');
    });

    test('albumId is empty when no album info is present', () {
      final Song s = Song.fromMiguJson(<String, dynamic>{
        'name': 't',
        'contentId': '111',
        'songId': '111',
      });
      expect(s.ref['albumId'], '');
      expect(s.ref['songId'], '111');
    });
  });

  group('Playlist.alg + lowercase playcount (additive)', () {
    test('fromJson reads alg and the recommend lowercase playcount', () {
      final Playlist p = Playlist.fromJson(<String, dynamic>{
        'id': 7,
        'name': 'rec',
        'picUrl': 'http://p.example/c.jpg',
        'playcount': 12345,
        'trackCount': 30,
        'alg': 'alg_mgc_red',
        'creator': <String, dynamic>{'nickname': 'dj'},
      });
      expect(p.alg, 'alg_mgc_red');
      expect(p.playCount, 12345);
      expect(p.trackCount, 30);
      expect(p.creatorName, 'dj');
    });

    test('uppercase playCount still wins when present; alg null when absent', () {
      final Playlist p = Playlist.fromJson(<String, dynamic>{
        'id': 8,
        'name': 'detail',
        'playCount': 99,
      });
      expect(p.playCount, 99);
      expect(p.alg, isNull);
    });

    test('copyWith carries alg and keeps existing fields', () {
      const Playlist p = Playlist(id: 1, name: 'x', alg: 'a1');
      expect(p.copyWith().alg, 'a1');
      expect(p.copyWith(alg: 'a2').alg, 'a2');

      final Playlist q = p.copyWith(trackCount: 5, playCount: 9);
      expect(q.trackCount, 5);
      expect(q.playCount, 9);
      expect(q.alg, 'a1');
    });
  });
}

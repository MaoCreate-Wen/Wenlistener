import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/models/lyric_line.dart';
import 'package:wenlistener/models/play_url.dart';
import 'package:wenlistener/models/playlist.dart';
import 'package:wenlistener/models/qr_login.dart';
import 'package:wenlistener/models/search_result.dart';
import 'package:wenlistener/models/song.dart';

void main() {
  group('Song.fromSearchJson', () {
    test('maps dt(ms)->Duration, ar[]->artists, al->album', () {
      final Song s = Song.fromSearchJson(<String, dynamic>{
        'id': 186016,
        'name': '七里香',
        'ar': <dynamic>[
          <String, dynamic>{'id': 6452, 'name': '周杰伦'},
          <String, dynamic>{'id': 1, 'name': 'feat'},
        ],
        'al': <String, dynamic>{
          'id': 18877,
          'name': '七里香',
          'picUrl': 'https://p.example/cover.jpg',
        },
        'dt': 299000,
        'fee': 1,
      });

      expect(s.id, 186016);
      expect(s.name, '七里香');
      expect(s.artists.length, 2);
      expect(s.artistNames, '周杰伦 / feat');
      expect(s.album?.name, '七里香');
      expect(s.artworkUrl, 'https://p.example/cover.jpg');
      expect(s.duration, const Duration(milliseconds: 299000));
      expect(s.fee, 1);
      expect(s.playable, isTrue);
    });

    test('detail json with privilege.st < 0 => not playable; copyWith', () {
      final Song s = Song.fromDetailJson(<String, dynamic>{
        'id': 42,
        'name': 'blocked',
        'ar': <dynamic>[],
        'dt': 1000,
        'privilege': <String, dynamic>{'st': -200},
      });
      expect(s.playable, isFalse);
      expect(s.copyWith(playable: true).playable, isTrue);
    });
  });

  group('AudioLevel', () {
    test('apiValue / encodeType / downloadBr', () {
      expect(AudioLevel.exhigh.apiValue, 'exhigh');
      expect(AudioLevel.exhigh.encodeType, 'aac');
      expect(AudioLevel.lossless.encodeType, 'flac');
      expect(AudioLevel.hires.encodeType, 'flac');
      expect(AudioLevel.standard.downloadBr, 128000);
      expect(AudioLevel.higher.downloadBr, 192000);
      expect(AudioLevel.exhigh.downloadBr, 320000);
      expect(AudioLevel.lossless.downloadBr, 999000);
    });
  });

  group('PlayUrl.fromJson', () {
    test('null url => not playable', () {
      final PlayUrl p = PlayUrl.fromJson(
        <String, dynamic>{'id': 1, 'url': null, 'br': 320000, 'type': 'mp3'},
        AudioLevel.exhigh,
      );
      expect(p.isPlayable, isFalse);
      expect(p.level, AudioLevel.exhigh);
    });

    test('real url => playable', () {
      final PlayUrl p = PlayUrl.fromJson(
        <String, dynamic>{
          'id': 1,
          'url': 'https://m.example/song.mp3',
          'br': 320000,
          'type': 'mp3',
          'size': 1234,
          'md5': 'abc',
        },
        AudioLevel.exhigh,
      );
      expect(p.isPlayable, isTrue);
      expect(p.br, 320000);
      expect(p.md5, 'abc');
    });
  });

  group('SearchType', () {
    test('codes match the wire values', () {
      expect(SearchType.song.code, 1);
      expect(SearchType.album.code, 10);
      expect(SearchType.artist.code, 100);
      expect(SearchType.playlist.code, 1000);
      expect(SearchType.lyric.code, 1006);
      expect(SearchType.comprehensive.code, 1018);
    });
  });

  group('SearchResult.fromJson', () {
    test('parses songs + hasMore from total', () {
      final SearchResult r = SearchResult.fromJson(
        <String, dynamic>{
          'songs': <dynamic>[
            <String, dynamic>{
              'id': 1,
              'name': 'a',
              'ar': <dynamic>[
                <String, dynamic>{'id': 1, 'name': 'x'}
              ],
              'dt': 1000,
            },
          ],
          'songCount': 50,
        },
        SearchType.song,
      );
      expect(r.songs.length, 1);
      expect(r.total, 50);
      expect(r.hasMore, isTrue);
      expect(SearchResult.empty().songs, isEmpty);
    });
  });

  group('Playlist.fromJson', () {
    test('detail shape with creator + tracks; copyWith replaces tracks', () {
      final Playlist p = Playlist.fromJson(<String, dynamic>{
        'id': 7,
        'name': 'My Mix',
        'coverImgUrl': 'https://p.example/pl.jpg',
        'creator': <String, dynamic>{'nickname': 'dj'},
        'description': 'desc',
        'trackCount': 2,
        'tracks': <dynamic>[
          <String, dynamic>{
            'id': 1,
            'name': 's1',
            'ar': <dynamic>[],
            'dt': 1000,
          },
        ],
      });
      expect(p.name, 'My Mix');
      expect(p.creatorName, 'dj');
      expect(p.coverUrl, 'https://p.example/pl.jpg');
      expect(p.tracks.length, 1);
      expect(p.copyWith(tracks: const <Song>[]).tracks, isEmpty);
    });
  });

  group('Lyrics.parse', () {
    test('plain LRC: lines sorted, indexAt picks the active line', () {
      final Lyrics ly = Lyrics.parse(
        lrc: '[00:01.00]line one\n[00:05.50]line two\n[00:10.00]line three',
      );
      expect(ly.lines.length, 3);
      expect(ly.hasWordByWord, isFalse);
      expect(ly.indexAt(const Duration(milliseconds: 500)), -1);
      expect(ly.indexAt(const Duration(seconds: 6)), 1);
      expect(ly.indexAt(const Duration(seconds: 20)), 2);
    });

    test('klyric: word-by-word words populated', () {
      final Lyrics ly = Lyrics.parse(
        klyric: '[00:00.000](0,500,0)Hello (500,500,0)World',
      );
      expect(ly.hasWordByWord, isTrue);
      expect(ly.lines.first.isWordByWord, isTrue);
      expect(ly.lines.first.words.length, 2);
      expect(ly.lines.first.words.first.text.trim(), 'Hello');
    });

    test('empty input => Lyrics.empty', () {
      expect(Lyrics.parse().lines, isEmpty);
      expect(Lyrics.empty.lines, isEmpty);
    });
  });

  group('QrPollResult.statusFromCode', () {
    test('canonical code map', () {
      expect(QrPollResult.statusFromCode(800), QrStatus.expired);
      expect(QrPollResult.statusFromCode(801), QrStatus.waitingScan);
      expect(QrPollResult.statusFromCode(802), QrStatus.scanned);
      expect(QrPollResult.statusFromCode(803), QrStatus.authorized);
      expect(QrPollResult.statusFromCode(860), QrStatus.invalidated);
      expect(QrPollResult.statusFromCode(0), QrStatus.unknown);
    });
  });
}

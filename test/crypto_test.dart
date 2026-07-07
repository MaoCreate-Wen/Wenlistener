import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/models/lyric_line.dart';
import 'package:wenlistener/services/netease_crypto.dart';

void main() {
  const NeteaseCrypto crypto = NeteaseCrypto();
  final RegExp lowerHex = RegExp(r'^[0-9a-f]+$');
  final RegExp upperHex = RegExp(r'^[0-9A-F]+$');

  group('weapi encryption', () {
    test('encSecKey is exactly 256 lowercase-hex chars', () {
      final WeapiPayload p = crypto.weapi(<String, dynamic>{
        's': '周杰伦',
        'type': 1,
        'limit': 30,
        'offset': 0,
      });
      expect(p.encSecKey.length, 256);
      expect(lowerHex.hasMatch(p.encSecKey), isTrue,
          reason: 'encSecKey must be lowercase hex');
    });

    test('params is valid base64', () {
      final WeapiPayload p =
          crypto.weapi(<String, dynamic>{'id': 123, 'csrf_token': ''});
      // Will throw FormatException if not valid base64.
      final List<int> decoded = base64.decode(p.params);
      expect(decoded.isNotEmpty, isTrue);
      // AES-CBC output is block-aligned (16 bytes).
      expect(decoded.length % 16, 0);
    });

    test('toForm exposes both fields', () {
      final WeapiPayload p = crypto.weapi(<String, dynamic>{'type': 1});
      final Map<String, dynamic> form = p.toForm();
      expect(form['params'], p.params);
      expect(form['encSecKey'], p.encSecKey);
    });

    test('randomBase62 yields requested length from the base62 charset', () {
      final String k = NeteaseCrypto.randomBase62(16);
      expect(k.length, 16);
      expect(RegExp(r'^[0-9a-zA-Z]+$').hasMatch(k), isTrue);
      expect(NeteaseCrypto.randomBase62(24).length, 24);
    });

    test('each call uses a fresh random key (params differ)', () {
      final WeapiPayload a = crypto.weapi(<String, dynamic>{'type': 1});
      final WeapiPayload b = crypto.weapi(<String, dynamic>{'type': 1});
      // Same payload, but random key per call -> different ciphertext + key.
      expect(a.encSecKey == b.encSecKey, isFalse);
    });

    test('constants match the spec', () {
      expect(NeteaseCrypto.fixedAesKey, '0CoJUm6Qyw8W8jud');
      expect(NeteaseCrypto.aesIv, '0102030405060708');
      expect(NeteaseCrypto.rsaPubExp, BigInt.from(0x10001));
    });
  });

  group('eapi encryption', () {
    test('eapi() returns non-empty even-length uppercase hex', () {
      final String out = crypto.eapi('/api/song/lyric/v1', <String, dynamic>{
        'id': '123',
        'cp': false,
        'tv': 0,
        'lv': 0,
        'rv': 0,
        'kv': 0,
        'yv': 0,
        'ytv': 0,
        'yrv': 0,
      });
      expect(out.isNotEmpty, isTrue);
      // AES-128-ECB output is block-aligned (16 bytes) → hex length is even.
      expect(out.length.isEven, isTrue);
      expect(upperHex.hasMatch(out), isTrue,
          reason: 'eapi output must be uppercase hex');
    });

    test('eapiKey constant matches the spec', () {
      expect(NeteaseCrypto.eapiKey, 'e82ckenh8dichen8');
    });

    test('distinct payloads produce distinct ciphertext', () {
      final String a = crypto.eapi('/api/song/lyric/v1',
          <String, dynamic>{'id': '1'});
      final String b = crypto.eapi('/api/song/lyric/v1',
          <String, dynamic>{'id': '2'});
      // ECB is deterministic (no IV), so the same input is stable, but a
      // different id must change the signed plaintext + digest → ciphertext.
      expect(a == b, isFalse);
    });
  });

  group('YRC (word-by-word) parsing', () {
    test('synthetic YRC → 1 line, 2 words, trailing space preserved', () {
      // SYNTHETIC gibberish only. A YRC line is
      // `[lineStartMs,lineDurMs](wStartMs,wDurMs,0)word…`.
      final Lyrics lyrics =
          Lyrics.parse(klyric: '[0,800](0,400,0)la (400,400,0)la ');
      expect(lyrics.lines.length, 1);
      expect(lyrics.hasWordByWord, isTrue);

      final LyricLine line = lyrics.lines.first;
      expect(line.words.length, 2);
      // The inter-word trailing space is load-bearing for the render-side Wrap
      // and must NOT be trimmed off the word text.
      expect(line.words[0].text, 'la ');
      expect(line.words[0].text.endsWith(' '), isTrue);
      expect(line.words[1].text, 'la');

      // Word timings: relative offsets folded onto the line start.
      expect(line.words[0].start, Duration.zero);
      expect(line.words[0].end, const Duration(milliseconds: 400));
      expect(line.words[1].start, const Duration(milliseconds: 400));
      expect(line.words[1].end, const Duration(milliseconds: 800));
    });
  });
}

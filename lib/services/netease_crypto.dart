import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The encrypted form body for a weapi request.
class WeapiPayload {
  /// `params` — base64 of the double AES-CBC pass.
  final String params;

  /// `encSecKey` — 256 lowercase-hex chars (textbook RSA of the reversed key).
  final String encSecKey;

  const WeapiPayload({required this.params, required this.encSecKey});

  Map<String, dynamic> toForm() =>
      <String, dynamic>{'params': params, 'encSecKey': encSecKey};
}

/// weapi encryption (`encrypt.py` port).
///
/// 1. `text = jsonEncode(payload)`
/// 2. `randKey` = 16 random base62 chars
/// 3. `e1 = base64(AES-128-CBC(text, FIXED_AES_KEY, IV, PKCS7))`
/// 4. `params = base64(AES-128-CBC(e1, randKey, IV, PKCS7))`
/// 5. `encSecKey = rsaNoPad(reverse(randKey))` -> 256-char lowercase hex
/// 6. body = {params, encSecKey}
class NeteaseCrypto {
  const NeteaseCrypto();

  static const String fixedAesKey = '0CoJUm6Qyw8W8jud';
  static const String aesIv = '0102030405060708';

  /// eapi (desktop) AES-128-ECB key (`encrypt.py:EAPI_KEY`).
  static const String eapiKey = 'e82ckenh8dichen8';

  static final BigInt rsaPubExp = BigInt.from(0x10001);

  static const String rsaModulusHex =
      '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';

  static final BigInt _rsaModulus = BigInt.parse(rsaModulusHex, radix: 16);

  static const String _base62 =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  static final Random _random = Random.secure();

  /// Encrypts [payload] into a [WeapiPayload].
  WeapiPayload weapi(Map<String, dynamic> payload) {
    final String text = jsonEncode(payload);
    final String randKey = randomBase62(16);
    final String e1 = _aesBase64(text, fixedAesKey);
    final String params = _aesBase64(e1, randKey);
    final String encSecKey = _rsaNoPad(randKey);
    return WeapiPayload(params: params, encSecKey: encSecKey);
  }

  /// eapi (desktop) encryption (`encrypt.py:eapi_encrypt` port). Unlike weapi
  /// there is no RSA / encSecKey — the body is a single `params=<hex>` field.
  ///
  /// 1. `text = jsonEncode(payload)`
  /// 2. `digest = md5Hex('nobody' + path + 'use' + text + 'md5forencrypt')`
  ///    (LOWERCASE hex — it's folded into the signed plaintext)
  /// 3. `data = '<path>-36cd479b6b5-<text>-36cd479b6b5-<digest>'`
  /// 4. output = hex(AES-128-ECB(PKCS7(utf8(data)), eapiKey)).toUpperCase()
  ///
  /// [path] is the api path WITHOUT the `/eapi` prefix (e.g.
  /// `/api/song/lyric/v1`).
  String eapi(String path, Map<String, dynamic> payload) {
    final String text = jsonEncode(payload);
    final String digest = _md5Hex('nobody${path}use${text}md5forencrypt');
    final String data = '$path-36cd479b6b5-$text-36cd479b6b5-$digest';
    final Uint8List out = _aesEcb(
      Uint8List.fromList(utf8.encode(data)),
      Uint8List.fromList(utf8.encode(eapiKey)),
    );
    return _hex(out, upper: true);
  }

  /// 16-by-default random base62 (a-zA-Z0-9) string.
  static String randomBase62([int len = 16]) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < len; i++) {
      sb.write(_base62[_random.nextInt(_base62.length)]);
    }
    return sb.toString();
  }

  String _aesBase64(String text, String key) {
    final Uint8List out = _aesCbc(
      Uint8List.fromList(utf8.encode(text)),
      Uint8List.fromList(utf8.encode(key)),
      Uint8List.fromList(utf8.encode(aesIv)),
    );
    return base64.encode(out);
  }

  Uint8List _aesCbc(Uint8List data, Uint8List key, Uint8List iv) {
    final PaddedBlockCipher cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
    return cipher.process(data);
  }

  String _rsaNoPad(String randKey) {
    // Reverse the key bytes (base62 == single-byte ASCII), interpret as a
    // big-endian BigInt, then textbook RSA: c = m^e mod n.
    final List<int> reversed = utf8.encode(randKey).reversed.toList();
    BigInt m = BigInt.zero;
    for (final int b in reversed) {
      m = (m << 8) | BigInt.from(b);
    }
    final BigInt c = m.modPow(rsaPubExp, _rsaModulus);
    return c.toRadixString(16).padLeft(256, '0');
  }

  /// AES-128-ECB encrypt with PKCS7 padding (the eapi cipher; no IV).
  Uint8List _aesEcb(Uint8List data, Uint8List key) {
    final PaddedBlockCipher cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      ECBBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          KeyParameter(key),
          null,
        ),
      );
    return cipher.process(data);
  }

  /// Lowercase hex MD5 of [input] (UTF-8).
  String _md5Hex(String input) {
    final Uint8List out =
        MD5Digest().process(Uint8List.fromList(utf8.encode(input)));
    return _hex(out, upper: false);
  }

  /// Hex-encodes [bytes]; uppercase when [upper] is set.
  String _hex(List<int> bytes, {bool upper = false}) {
    final StringBuffer sb = StringBuffer();
    for (final int b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    final String s = sb.toString();
    return upper ? s.toUpperCase() : s;
  }
}

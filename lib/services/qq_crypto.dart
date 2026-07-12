import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Pure-Dart port of QQ Music's web request crypto (`Spider/QQMusic/
/// qqmusic_crypto_py.py`). The encrypted gateway `musics.fcg?encoding=ag-1` needs
/// three things: a `sign` derived from the plaintext body, an AES-128-GCM
/// encrypted body, and matching response decryption. All three are clean,
/// deterministic algorithms (no jsvmp / JS engine) — unit-tested against the
/// Python's golden vectors (`test/crypto/qq_crypto_test.dart`).
class QqCrypto {
  const QqCrypto();

  static const String _signPrefix = 'zzc';
  // SHA-1 digest XOR key (20 bytes) for the sign's middle segment.
  static final Uint8List _signXorKey =
      _hex('5927B396DA523AFCB134BA7B7840F2858FA179B3');
  // AES-128-GCM key (16 bytes) for request encrypt + GCM response decrypt.
  static final Uint8List _aesKey = _hex('bd305f10d0ff74b6ef54dab835b5e1cf');
  // XOR key (21 bytes) for the common `0x01`-prefixed response variant.
  static final Uint8List _respXorKey =
      _hex('7a3f8c1d5e9b2f0a6c4d7e8b1f3a5c9d0e2b6f4a81');
  static const List<int> _headIdx = <int>[23, 14, 6, 36, 16, 40, 7, 19];
  static const List<int> _tailIdx = <int>[16, 1, 32, 12, 19, 27, 8, 5];

  /// The `zzc…` signature for a compact-JSON [plain] body. SHA-1 the plaintext,
  /// then: head = selected uppercase-hex chars, middle = base64(digest XOR key)
  /// stripped of `= / +`, tail = more hex chars; concat under `zzc` and lowercase.
  String securitySign(String plain) {
    final Uint8List digest =
        SHA1Digest().process(Uint8List.fromList(utf8.encode(plain)));
    final String hex = _hexUpper(digest); // 40 chars

    final StringBuffer head = StringBuffer();
    for (final int i in _headIdx) {
      if (i < hex.length) head.write(hex[i]); // index 40 (>=len) is skipped
    }
    final Uint8List middleRaw = Uint8List(digest.length);
    for (int i = 0; i < digest.length; i++) {
      middleRaw[i] = digest[i] ^ _signXorKey[i];
    }
    final String middle = base64
        .encode(middleRaw)
        .replaceAll('=', '')
        .replaceAll('/', '')
        .replaceAll('+', '');
    final StringBuffer tail = StringBuffer();
    for (final int i in _tailIdx) {
      if (i < hex.length) tail.write(hex[i]);
    }
    return ('$_signPrefix$head$middle$tail').toLowerCase();
  }

  /// Encrypts a plaintext body: `base64(iv(12) + ciphertext + tag(16))` under
  /// AES-128-GCM. A random IV is used unless [iv] is supplied (tests pass one for
  /// determinism).
  String cgiEncrypt(String plain, {Uint8List? iv}) {
    final Uint8List nonce = iv ?? _randomIv();
    final Uint8List ctTag =
        _gcm(true, nonce, Uint8List.fromList(utf8.encode(plain)));
    final Uint8List out = Uint8List(nonce.length + ctTag.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + ctTag.length, ctTag);
    return base64.encode(out);
  }

  /// Decrypts a response body (raw bytes or a base64 string). Three cases, in the
  /// Python's order: already-plaintext JSON, `0x01`-prefixed XOR, else AES-GCM.
  String cgiDecrypt(dynamic data) {
    final Uint8List raw = data is String
        ? base64.decode(data)
        : Uint8List.fromList(data as List<int>);

    // Case 1: already plaintext JSON (rare).
    int s = 0;
    while (s < raw.length && _isWs(raw[s])) {
      s++;
    }
    if (s < raw.length && (raw[s] == 0x7b /*{*/ || raw[s] == 0x5b /*[*/)) {
      return utf8.decode(raw, allowMalformed: true);
    }

    // Case 2: `0x01`-prefixed XOR (most common).
    if (raw.isNotEmpty && raw[0] == 0x01) {
      final Uint8List out = Uint8List(raw.length);
      for (int i = 0; i < raw.length; i++) {
        out[i] = raw[i] ^ _respXorKey[i % _respXorKey.length];
      }
      return utf8.decode(out, allowMalformed: true);
    }

    // Case 3: AES-GCM (iv | ciphertext | tag).
    final Uint8List ivPart = raw.sublist(0, 12);
    final Uint8List ctTag = raw.sublist(12);
    final Uint8List plain = _gcm(false, ivPart, ctTag);
    return utf8.decode(plain, allowMalformed: true);
  }

  // --- helpers -------------------------------------------------------------

  /// AES-128-GCM one-shot. Encrypt → ciphertext+tag; decrypt → plaintext (throws
  /// on tag mismatch). 128-bit tag, empty AAD — matching pycryptodome's defaults.
  Uint8List _gcm(bool forEncryption, Uint8List iv, Uint8List data) {
    final GCMBlockCipher cipher = GCMBlockCipher(AESEngine())
      ..init(
        forEncryption,
        AEADParameters(KeyParameter(_aesKey), 128, iv, Uint8List(0)),
      );
    final Uint8List out = Uint8List(cipher.getOutputSize(data.length));
    final int len = cipher.processBytes(data, 0, data.length, out, 0);
    final int fin = cipher.doFinal(out, len);
    return out.sublist(0, len + fin);
  }

  static Uint8List _randomIv() {
    final Random rng = Random.secure();
    final Uint8List iv = Uint8List(12);
    for (int i = 0; i < 12; i++) {
      iv[i] = rng.nextInt(256);
    }
    return iv;
  }

  static bool _isWs(int b) =>
      b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d;

  static String _hexUpper(Uint8List b) {
    final StringBuffer sb = StringBuffer();
    for (final int x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString().toUpperCase();
  }

  static Uint8List _hex(String s) {
    final Uint8List out = Uint8List(s.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

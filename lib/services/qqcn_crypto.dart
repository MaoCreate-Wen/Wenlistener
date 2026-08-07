import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Pure-Dart port of QQ Music's **Android** request crypto (reverse-engineered in
/// `spider/QQmusic_Android/tools/qqmusic_sign_final.py`, fully verified against the
/// native `libmer.so` B542C/B1750 routines via Frida RPC). The Android gateway
/// `u6.y.qq.com/cgi-bin/musics.fcg` needs two headers derived from the compact-JSON
/// body:
///
///  * `sign` — `base64( BionicRand(epochSec).randLetters(12) +
///    HMAC_SHA1("9FF169D646A3", reversed(base64(body))) )`.
///  * `mask` — `base64( b542c( "11&20070008&{uid}&null&{tsMs}&{udid}&android",
///    key = ascii(sign[:8] + sign[-8:]) ) )` — a TEA-CBC variant.
///
/// `musicu.fcg` (login exchange / GetSession) uses only the `sign` header and a
/// raw JSON body. All algorithms are clean and deterministic — no jsvmp / JS
/// engine. [QqcnCrypto] stays a `const` shell (the ctor default in [QqcnApi]); the
/// heavy state lives in [BionicRand] / the top-level [b542cEncrypt] / [teaEncryptBlock].
class QqcnCrypto {
  const QqcnCrypto();

  /// HMAC-SHA1 key (12 ASCII bytes) — `sub_BD33C` in libmer.so.
  static final Uint8List _hmacKey =
      Uint8List.fromList(ascii.encode('9FF169D646A3'));

  /// App version string baked into the mask join.
  static const String appVersion = '20070008';

  static const int _mask32 = 0xFFFFFFFF;

  /// Computes the request `sign` header over the compact-JSON [bodyBytes] (the
  /// EXACT bytes that get zlib-compressed and sent — the server re-derives the
  /// HMAC from the decompressed body, so nothing else needs canonicalising).
  ///
  /// [epochSec] seeds [BionicRand] for the 12-letter prefix; pass `null` for
  /// `now`. Returns a 44-char base64 string.
  String signBody(Uint8List bodyBytes, {int? epochSec}) {
    final int seed = epochSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    // msg = reversed bytes of base64(body).
    final Uint8List b64 = Uint8List.fromList(ascii.encode(base64.encode(bodyBytes)));
    final Uint8List msg = Uint8List(b64.length);
    for (int i = 0; i < b64.length; i++) {
      msg[i] = b64[b64.length - 1 - i];
    }
    final HMac hmac = HMac(SHA1Digest(), 64)..init(KeyParameter(_hmacKey));
    final Uint8List digest = hmac.process(msg); // 20 bytes
    final String prefix = BionicRand(seed).randLetters(12);
    final Uint8List composite = Uint8List(12 + digest.length)
      ..setRange(0, 12, ascii.encode(prefix))
      ..setRange(12, 12 + digest.length, digest);
    return base64.encode(composite);
  }

  /// Computes the `mask` header for a `musics.fcg` request. [sign] is the string
  /// returned by [signBody]; its first-8 + last-8 chars form the 16-byte TEA key.
  /// [epochSec] seeds the (discarded) B542C block-0 randomness.
  String maskFor({
    required String uid,
    required String udid,
    required int tsMs,
    required String sign,
    int? epochSec,
  }) {
    final int seed = epochSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final String join = '11&$appVersion&$uid&null&$tsMs&$udid&android';
    final String keyStr =
        sign.substring(0, 8) + sign.substring(sign.length - 8);
    final Uint8List key = Uint8List.fromList(ascii.encode(keyStr)); // 16 bytes
    final Uint8List enc = b542cEncrypt(
      Uint8List.fromList(utf8.encode(join)),
      key,
      randSeed: seed,
    );
    return base64.encode(enc);
  }

  /// QQ's `hash33` (base 0): `r = r + (r<<5) + c` over the code units, masked to
  /// 31 bits. Used for the ptlogin `ptqrtoken` AND the OAuth / musicu `g_tk`
  /// (both are the base-0 variant in the verified Android login — NOT the classic
  /// web base-5381 g_tk).
  static int hash33(String s) {
    int h = 0;
    for (final int c in s.codeUnits) {
      h = (h + ((h << 5) & _mask32) + c) & _mask32;
    }
    return h & 0x7fffffff;
  }
}

/// Android bionic libc `srand`/`rand` reimplementation (static-linked `sub_4EF90`
/// in libmer.so — verified 12/12 against captured `sign` prefixes). Deterministic
/// from a 32-bit seed.
class BionicRand {
  static const int _mask32 = 0xFFFFFFFF;

  final List<int> _state = List<int>.filled(31, 0);
  int _fptr = 3;
  int _rptr = 0;

  BionicRand([int? seed]) {
    if (seed != null) srand(seed);
  }

  void srand(int seed) {
    _state[0] = seed & _mask32;
    for (int i = 1; i < 31; i++) {
      // (16807 * state[i-1]) % 2147483647 — fits in 53 bits before the mod.
      _state[i] = (16807 * _state[i - 1]) % 2147483647;
    }
    _fptr = 3;
    _rptr = 0;
    for (int i = 0; i < 310; i++) {
      _step();
    }
  }

  int _step() {
    _state[_fptr] = (_state[_fptr] + _state[_rptr]) & _mask32;
    final int val = (_state[_fptr] >> 1) & 0x7fffffff;
    _fptr = (_fptr + 1) % 31;
    _rptr = (_rptr + 1) % 31;
    return val;
  }

  /// `n` uppercase letters: `chr((rand() % 26) + 'A')`.
  String randLetters(int n) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < n; i++) {
      sb.writeCharCode((_step() % 26) + 65);
    }
    return sb.toString();
  }

  /// One random byte (`rand() & 0xFF`).
  int randByte() => _step() & 0xFF;
}

/// Standard TEA block encrypt: 16 rounds, big-endian word order, delta 0x9E3779B9
/// (`sub_B1750`). [block8] and [key16] are exactly 8 / 16 bytes.
Uint8List teaEncryptBlock(Uint8List block8, Uint8List key16) {
  const int mask = 0xFFFFFFFF;
  int v0 = _beU32(block8, 0);
  int v1 = _beU32(block8, 4);
  final int k0 = _beU32(key16, 0);
  final int k1 = _beU32(key16, 4);
  final int k2 = _beU32(key16, 8);
  final int k3 = _beU32(key16, 12);
  const int delta = 0x9E3779B9;
  int s = 0;
  for (int i = 0; i < 16; i++) {
    s = (s + delta) & mask;
    v0 = (v0 +
            ((((v1 << 4) + k0) & mask) ^
                ((v1 + s) & mask) ^
                (((v1 >> 5) + k1) & mask))) &
        mask;
    v1 = (v1 +
            ((((v0 << 4) + k2) & mask) ^
                ((v0 + s) & mask) ^
                (((v0 >> 5) + k3) & mask))) &
        mask;
  }
  final Uint8List out = Uint8List(8);
  _putBeU32(out, 0, v0);
  _putBeU32(out, 4, v1);
  return out;
}

/// B542C TEA-CBC-variant encryption (`sub_B542C`, OLLVM-obfuscated). Output length
/// is `ceil((N+10)/8) * 8`. The block-0 randomness is discarded server-side, so
/// [randSeed] only needs to be self-consistent.
///
/// Block 0: 8 pseudo-random bytes; byte0's low 3 bits encode the padding length.
/// Block i (1..K-1): `v171 = chunk XOR prevOut XOR M`, `out = TEA(v171) XOR v170`,
/// where `M[j] = data[pos+j] XOR data[pos+j+1]` (consecutive diffs, zero-padded)
/// and `v170` carries the previous block's `v171`.
Uint8List b542cEncrypt(Uint8List data, Uint8List key16, {int? randSeed}) {
  final int n = data.length;
  final int v150 = (n + 10) - ((n + 10) & ~7); // (n+10) % 8
  final int k = (n + 10 + 7) ~/ 8; // ceil((n+10)/8)
  final int v142 = 8 - v150;

  final BionicRand rng =
      BionicRand(randSeed ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000));

  Uint8List v170 = Uint8List(8); // zero
  final List<int> resultBytes = <int>[];

  for (int i = 0; i < k; i++) {
    Uint8List v171;
    if (i == 0) {
      v171 = Uint8List(8);
      for (int j = 0; j < 8; j++) {
        v171[j] = rng.randByte();
      }
      v171[0] = (v171[0] & 0xF8) | v142;
    } else {
      final int pos = (i - 1) * 8;
      final Uint8List chunk = Uint8List(8);
      for (int j = 0; j < 8; j++) {
        chunk[j] = (pos + j < n) ? data[pos + j] : 0;
      }
      final Uint8List m = Uint8List(8);
      for (int j = 0; j < 8; j++) {
        final int a = (pos + j < n) ? data[pos + j] : 0;
        final int b = (pos + j + 1 < n) ? data[pos + j + 1] : 0;
        m[j] = a ^ b;
      }
      v171 = Uint8List(8);
      for (int j = 0; j < 8; j++) {
        final int prevOut = resultBytes[(i - 1) * 8 + j];
        v171[j] = chunk[j] ^ prevOut ^ m[j];
      }
    }
    final Uint8List teaOut = teaEncryptBlock(v171, key16);
    final Uint8List outBlk = Uint8List(8);
    for (int j = 0; j < 8; j++) {
      outBlk[j] = teaOut[j] ^ v170[j];
    }
    resultBytes.addAll(outBlk);
    v170 = v171;
  }
  return Uint8List.fromList(resultBytes);
}

int _beU32(Uint8List b, int off) =>
    ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) &
    0xFFFFFFFF;

void _putBeU32(Uint8List b, int off, int v) {
  b[off] = (v >> 24) & 0xFF;
  b[off + 1] = (v >> 16) & 0xFF;
  b[off + 2] = (v >> 8) & 0xFF;
  b[off + 3] = v & 0xFF;
}

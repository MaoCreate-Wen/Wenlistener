import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Pure-Dart port of the Kugou 概念版 (FreeListen / Lite Android app) request
/// crypto — a faithful re-implementation of `Code/spider/kugougn/kugou_client.py`
/// (constants, `sign`, `gen_t1`/`gen_t2`, `gen_time_key`, `gen_v5_url_key`, the
/// `aes_encrypt`/`aes_decrypt_secu` secu layer, `rsa_encrypt`, and the dynamic
/// `KG-RF`/`KG-THash` header machinery). Every algorithm here is a clean,
/// deterministic function (no Frida / native bridge): the App's own libj.so
/// t1/t2 tokens are reproduced purely from the derived AES keys below.
///
/// Golden vectors verified against the Python (ts=1785688871123):
///  * gen_v5_url_key('1822697a…','2047315…','929811562') == 01070b3012d8e9b164954c4ef8f36c1e
///    (== the `key` in the captured `v5/url` request, `API.md`)
///  * gen_t2 prefix == the captured `KG-DEVID` header.
class KugouCrypto {
  KugouCrypto();

  // ===== static app / device constants (DeviceCreds) =======================
  static const String appKey = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';
  static const String appId = '3116';
  static const String clientVer = '11520';
  static const String trackerPidVersion = '3001';
  static const String trackerPidVersionSecret =
      '185672dd44712f60bb1736df5a377e82';

  static const String mid = '204731576040690811045114741581857116889';
  static const String uuid = '-';
  static const String dfid = '3we8nE2QmzBi3pDCaZ0rgib2';
  static const String deviceModel = '22021211RC';
  static const String gitVersion = 'ffb9554';
  static const String originAndroidId = 'fa8a4661274eb396';
  static const String mac = '02:00:00:00:00:00';
  static const String osVersion = '14';
  static const String pageId = '671299534';
  static const String ppageId = '356753938,695084294';

  /// RSA-1024 public key from the App (X.509 SPKI). Extracted modulus/exponent
  /// (`RSA/ECB/NOPADDING`, textbook RSA over a 128-byte right-zero-padded block).
  static final BigInt _rsaN = BigInt.parse(
    'c40a2d0da76511f3bb1cc2bbd3afbd8bea83b4d6b05b6c13eb8920c53f1af767'
    '9b32ba0d0edb843240ef1b836efed3ee240734c14c1399fd6594d16af22f5252'
    '5d14d72e0155c6dcc8638d4f7bb94f3a0b1f4c29f991972f2a160a25eb0a9e724'
    '336be7f69bbd319ffab1c6dd8470b021dc434f3faba89f4a2a01b33bdbdd08b',
    radix: 16,
  );
  static final BigInt _rsaE = BigInt.from(65537);
  static const int _rsaBytes = 128;

  // ===== t1 / t2 keys (reversed from libj.so) ==============================
  // T1_KEY / T1_IV are ASCII strings used directly as AES-256 key + 16-byte IV.
  static final Uint8List _t1Key =
      Uint8List.fromList(ascii.encode('5e4ef500e9597fe004bd09a46d8add98'));
  static final Uint8List _t1Iv =
      Uint8List.fromList(ascii.encode('04bd09a46d8add98'));

  // T2_KEY is the obfuscated blob XORed byte-for-byte with a 16-byte table over
  // its first 16 bytes (the derivation, not the result, per the reference). It
  // resolves to the ASCII AES-256 key "fd14b35e3f81af3817a20ae7adae7020".
  static final Uint8List _t2Obfuscated = Uint8List.fromList(<int>[
    0x47, 0x64, 0x56, 0x42, 0x3E, 0x2B, 0x67, 0x53, 0x57, 0x7D, 0x71, 0x13,
    0x2A, 0x68, 0x52, 0x16, // first 16 → XORed
    0x31, 0x37, 0x61, 0x32, 0x30, 0x61, 0x65, 0x37, 0x61, 0x64, 0x61, 0x65,
    0x37, 0x30, 0x32, 0x30, // "17a20ae7adae7020" (unchanged)
  ]);
  static final Uint8List _t2XorTable = _hexToBytes(
      '210067765c185236641b49224b0e612e');
  static final Uint8List _t2Key = _deriveT2Key();
  static final Uint8List _t2Iv =
      Uint8List.fromList(ascii.encode('17a20ae7adae7020'));

  static Uint8List _deriveT2Key() {
    final Uint8List out = Uint8List(_t2Obfuscated.length);
    for (int i = 0; i < _t2Obfuscated.length; i++) {
      out[i] = i < _t2XorTable.length
          ? _t2Obfuscated[i] ^ _t2XorTable[i]
          : _t2Obfuscated[i];
    }
    return out;
  }

  // android_id = MD5(ORIGIN_ANDROID_ID); mac_hash = MD5(MAC) — both lowercase.
  static final String _androidId = _md5HexStatic(originAndroidId);
  static final String _macHash = _md5HexStatic(mac);

  // ===== KG-RF dynamic header (AbsAckInterceptor) ==========================
  static const String _kgRfDeviceSuffix = '9A05DE0671CD63B3';
  static const int kgRfDefaultVersion = 32770;
  static const Map<String, int> _kgRfHostVersions = <String, int>{
    'gateway.kugou.com': 220,
    'login.user.kugou.com': 185,
    'loginserviceretry.kugou.com': 185,
    'openapicdn.kugou.com': 115,
    'expendablekmrcdn.kugou.com': 116,
    'trackercdngz.kugou.com': 32770,
  };
  int _kgRfCounter = 0;

  // KG-THash endpoint map (okhttp Call stack hash → c.d(2)). Order matters: the
  // first UA-suffix substring match wins, else the default.
  static const Map<String, String> _thashMap = <String, String>{
    'FreeListen': '7be5004',
    'LOGIN': '327f70d',
    'SendMobileCode': '3e3c24c',
    'ChannelGetUserSong': '36abe5d',
    'ChannelTodayFeatured': '54f5a5c',
    'mediastore': '78e4aa3',
    'NetMusic': '3110dbc',
    'recommend': '3716054',
    'CloudMusic': '498fe44',
    'CloudMusicGetAllList': '4c3144e',
    'searchMainCover': '5d881d0',
    'multitrack': '58aec30',
  };
  static const String _defaultThash = '3cb2e6a';

  final Random _rng = Random.secure();

  // ===== signing ===========================================================

  /// `sign(params, suffix)` = MD5( APPKEY + Σ"k=v" (keys ascii-sorted) + suffix +
  /// APPKEY ). For POST requests [suffix] is the compact-JSON body text; for GET
  /// it is empty. Lowercase hex.
  String sign(Map<String, String> params, [String suffix = '']) {
    final List<String> keys = params.keys.toList()..sort();
    final StringBuffer sb = StringBuffer(appKey);
    for (final String k in keys) {
      sb
        ..write(k)
        ..write('=')
        ..write(params[k]);
    }
    sb
      ..write(suffix)
      ..write(appKey);
    return md5Hex(sb.toString());
  }

  /// `gen_time_key`: MD5(APPID + APPKEY + CLIENTVER + int(clienttime)). The App's
  /// CommonConfig user/recommend/cloud key. [clienttime] is a plain integer
  /// string (seconds or ms, per the caller).
  String genTimeKey(String clienttime) =>
      md5Hex('$appId$appKey$clientVer$clienttime');

  /// `gen_v5_url_key`: MD5(hash + TRACKER_SECRET + APPID + mid + userid). The
  /// UrlRequestor key for `v5/url`.
  String genV5UrlKey(String songHash, String userId) =>
      md5Hex('$songHash$trackerPidVersionSecret$appId$mid$userId');

  String md5Hex(String input) =>
      _hexLower(MD5Digest().process(Uint8List.fromList(utf8.encode(input))));

  static String _md5HexStatic(String input) {
    final Uint8List out =
        MD5Digest().process(Uint8List.fromList(utf8.encode(input)));
    return _hexLower(out);
  }

  // ===== t1 / t2 ===========================================================

  /// `gen_t1(ts_ms)` = hex( AES-256-CBC(T1_KEY, T1_IV, PKCS7("|" + ts_ms)) ).
  String genT1(int tsMs) {
    final Uint8List pt = Uint8List.fromList(utf8.encode('|$tsMs'));
    return _hexLower(_cbcEncryptPkcs7(pt, _t1Key, _t1Iv));
  }

  /// `gen_t2(ts_ms)` = hex( AES-256-CBC(T2_KEY, T2_IV,
  /// PKCS7("android_id|mac_hash|mac|model|ts_ms")) ).
  String genT2(int tsMs) {
    final String plain = <String>[
      _androidId,
      _macHash,
      mac,
      deviceModel,
      tsMs.toString(),
    ].join('|');
    return _hexLower(
        _cbcEncryptPkcs7(Uint8List.fromList(utf8.encode(plain)), _t2Key, _t2Iv));
  }

  // ===== secu AES layer (a.i / a.e) ========================================

  /// `aes_cipher_params(rand_key)` → (key, iv) as the ASCII bytes of MD5(rand_key)
  /// hex: key = full 32 hex chars (AES-256), iv = chars[16:32] (16 bytes).
  (Uint8List, Uint8List) _aesCipherParams(String randKey) {
    final String m = md5Hex(randKey);
    return (
      Uint8List.fromList(ascii.encode(m.substring(0, 32))),
      Uint8List.fromList(ascii.encode(m.substring(16, 32))),
    );
  }

  /// `aes_encrypt(plaintext, rand_key)` → UPPERCASE hex of AES-256-CBC(PKCS7).
  String aesEncrypt(String plaintext, String randKey) {
    final (Uint8List key, Uint8List iv) = _aesCipherParams(randKey);
    final Uint8List ct = _cbcEncryptPkcs7(
        Uint8List.fromList(utf8.encode(plaintext)), key, iv);
    return _hexUpper(ct);
  }

  /// `aes_decrypt_secu_params(hexdata, rand_key)` → AES-256-CBC/NoPadding decrypt
  /// then UTF-8 decode + Java `.trim()` (strip chars <= U+0020 at both ends).
  String aesDecryptSecu(String hexData, String randKey) {
    final (Uint8List key, Uint8List iv) = _aesCipherParams(randKey);
    final Uint8List pt = _cbcDecryptNoPad(_hexToBytes(hexData), key, iv);
    final String s = utf8.decode(pt, allowMalformed: true);
    return _trimControl(s);
  }

  // ===== RSA ===============================================================

  /// `rsa_encrypt(data)` — RSA/ECB/NOPADDING: right-zero-pad [data] to 128 bytes,
  /// textbook `c = m^e mod n`, return UPPERCASE hex (256 chars).
  String rsaEncrypt(String data) {
    final Uint8List text = Uint8List.fromList(utf8.encode(data));
    if (text.length > _rsaBytes) {
      throw ArgumentError('RSA plaintext too long: ${text.length}');
    }
    final Uint8List block = Uint8List(_rsaBytes)..setRange(0, text.length, text);
    BigInt m = BigInt.zero;
    for (final int b in block) {
      m = (m << 8) | BigInt.from(b);
    }
    final BigInt c = m.modPow(_rsaE, _rsaN);
    return c.toRadixString(16).padLeft(_rsaBytes * 2, '0').toUpperCase();
  }

  /// `rand_hex16` — 16 UPPERCASE hex chars (8 secure-random bytes).
  String randHex16() {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 8; i++) {
      sb.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString().toUpperCase();
  }

  // ===== KG-RF / KG-THash / headers ========================================

  int kgRfVersionForUrl(String url) {
    final String host = Uri.tryParse(url)?.host ?? '';
    return _kgRfHostVersions[host] ?? kgRfDefaultVersion;
  }

  /// `gen_kg_rf` — 128-bit token → 32 hex chars: version(8) + random(30) +
  /// counter(6) + timestamp-seconds(20) + device(64).
  String genKgRf(int version) {
    final int ctr = _kgRfCounter & 63;
    _kgRfCounter = (_kgRfCounter + 1) & 0xFFFFFFFF;
    final int rand = _rng.nextInt(0x3FFFFFFF) + 1; // 1 .. 0x3FFFFFFF
    final int secs =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) & 0xFFFFF;
    final StringBuffer bits = StringBuffer()
      ..write(_bin(version & 0xFF, 8))
      ..write(_bin(rand & 0x3FFFFFFF, 30))
      ..write(_bin(ctr, 6))
      ..write(_bin(secs, 20))
      ..write(_hexToBin(_kgRfDeviceSuffix));
    final String b = bits.toString();
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < b.length; i += 4) {
      out.write(int.parse(b.substring(i, i + 4), radix: 2)
          .toRadixString(16)
          .toUpperCase());
    }
    return out.toString();
  }

  String genKgThash(String uaSuffix) {
    final String lower = uaSuffix.toLowerCase();
    for (final MapEntry<String, String> e in _thashMap.entries) {
      if (lower.contains(e.key.toLowerCase())) return e.value;
    }
    return _defaultThash;
  }

  /// `build_headers` — the per-request UA + KG-* header block. [userIdFake] is
  /// the current userid when logged in, else "0" (KG-FAKE).
  Map<String, String> buildHeaders(
    String uaSuffix, {
    int? rfVersion,
    String userIdFake = '0',
  }) {
    return <String, String>{
      'User-Agent': 'Android$osVersion-1070-$clientVer-130-0-$uaSuffix',
      'Accept-Encoding': 'gzip, deflate',
      'kg-thash': genKgThash(uaSuffix),
      'kg-rec': '1',
      'kg-rc': '1',
      'kg-fake': userIdFake,
      'kg-rf': genKgRf(rfVersion ?? kgRfDefaultVersion),
      'kg-rfb': '0',
    };
  }

  // ===== AES / hex helpers =================================================

  Uint8List _cbcEncryptPkcs7(Uint8List data, Uint8List key, Uint8List iv) {
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

  Uint8List _cbcDecryptNoPad(Uint8List data, Uint8List key, Uint8List iv) {
    final CBCBlockCipher cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
    final Uint8List out = Uint8List(data.length);
    for (int off = 0; off + 16 <= data.length; off += 16) {
      cipher.processBlock(data, off, out, off);
    }
    return out;
  }

  static String _bin(int value, int width) {
    String s = value.toRadixString(2);
    if (s.length > width) s = s.substring(s.length - width);
    return s.padLeft(width, '0');
  }

  static String _hexToBin(String hex) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < hex.length; i++) {
      sb.write(int.parse(hex[i], radix: 16).toRadixString(2).padLeft(4, '0'));
    }
    return sb.toString();
  }

  static String _hexLower(List<int> bytes) {
    final StringBuffer sb = StringBuffer();
    for (final int b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static String _hexUpper(List<int> bytes) => _hexLower(bytes).toUpperCase();

  static Uint8List _hexToBytes(String s) {
    final Uint8List out = Uint8List(s.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// Java `String.trim()` — strips every char <= U+0020 from both ends.
  static String _trimControl(String s) {
    int start = 0;
    int end = s.length;
    while (start < end && s.codeUnitAt(start) <= 0x20) {
      start++;
    }
    while (end > start && s.codeUnitAt(end - 1) <= 0x20) {
      end--;
    }
    return s.substring(start, end);
  }
}

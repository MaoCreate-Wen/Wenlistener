import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/services/qq_crypto.dart';

void main() {
  const QqCrypto crypto = QqCrypto();

  group('QqCrypto.securitySign matches the Python golden vectors', () {
    // From `python -c "from qqmusic_crypto_py import get_security_sign; ..."`.
    const Map<String, String> vectors = <String, String>{
      'hello': 'zzcfa14dde89n1iwax0l5rimr0qwjexceiov4daaee8d6',
      '{"a":1}': 'zzc7746109xq501htmv4ipz7c8owlxfpihjm1fd695c7',
      'The quick brown fox': 'zzc12abc09nd5ynraj0dd1rvhat7u67bf5yvyc53e9b61',
    };
    vectors.forEach((String plain, String expected) {
      test('sign(${jsonEncode(plain)})', () {
        expect(crypto.securitySign(plain), expected);
      });
    });
  });

  test('cgiEncrypt → cgiDecrypt round-trips (AES-128-GCM)', () {
    const String plain = '{"comm":{"g_tk":5381},"req_1":{"module":"x"}}';
    final String enc = crypto.cgiEncrypt(plain);
    expect(crypto.cgiDecrypt(enc), plain);
  });

  test('cgiEncrypt with a fixed IV is deterministic + starts with that IV', () {
    final Uint8List iv = Uint8List.fromList(List<int>.generate(12, (int i) => i));
    const String plain = 'hello world';
    final String a = crypto.cgiEncrypt(plain, iv: iv);
    final String b = crypto.cgiEncrypt(plain, iv: iv);
    expect(a, b); // same IV → identical ciphertext
    expect(base64.decode(a).sublist(0, 12), iv);
    expect(crypto.cgiDecrypt(a), plain);
  });

  test('cgiDecrypt passes through already-plaintext JSON', () {
    final Uint8List json = Uint8List.fromList(utf8.encode('  {"code":0}'));
    expect(crypto.cgiDecrypt(json), '  {"code":0}');
  });

  test('cgiDecrypt reverses the 0x01-prefixed XOR variant', () {
    // Build a 0x01-prefixed XOR body the same way the server would, then decode.
    const String payload = '{"req_1":{"code":0}}';
    final List<int> plainBytes = utf8.encode(payload);
    // The XOR key from the Python (7a3f8c1d…). Reproduce the encode: out[i] =
    // in[i] ^ key[i % len]; the first byte must XOR to 0x01 for the branch to fire.
    final Uint8List key = Uint8List.fromList(<int>[
      0x7a, 0x3f, 0x8c, 0x1d, 0x5e, 0x9b, 0x2f, 0x0a, 0x6c, 0x4d, 0x7e, 0x8b,
      0x1f, 0x3a, 0x5c, 0x9d, 0x0e, 0x2b, 0x6f, 0x4a, 0x81,
    ]);
    // Prepend a leading byte so raw[0]==0x01 after XOR: we craft raw directly.
    final Uint8List raw = Uint8List(plainBytes.length + 1);
    raw[0] = 0x01;
    for (int i = 0; i < plainBytes.length; i++) {
      raw[i + 1] = plainBytes[i] ^ key[(i + 1) % key.length];
    }
    // The decrypt XORs the WHOLE buffer (including raw[0]); byte 0 → 0x01^0x7a.
    final String decoded = crypto.cgiDecrypt(raw);
    expect(decoded.substring(1), payload); // byte 0 is the marker, rest is JSON
  });
}

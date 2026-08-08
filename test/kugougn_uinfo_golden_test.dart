import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener_desktop/services/kugougn_crypto.dart';

void main() {
  // Golden vector from QQmusic_Android-adjacent kugougn API.md §4.7 (verified via
  // a Frida h14 hook on 2026-08-07): gen_u_info("Tk") must equal this exact hex.
  // AES-256-CBC/PKCS7, key=ascii("269b…136da"), iv=ascii("6a74…017"),
  // plaintext = compact JSON {"token":"Tk"}, output = lowercase hex.
  test('kugougn genUInfo("Tk") == golden vector', () {
    expect(
      KugougnCrypto().genUInfo('Tk'),
      '12a78c6c64afd27063c261c63b0836f3',
    );
  });
}

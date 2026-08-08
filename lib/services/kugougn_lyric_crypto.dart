import 'dart:io' show zlib;
import 'dart:convert' show utf8, base64;
import 'dart:typed_data';

/// 酷狗 KRC 逐字歌词解密。
///
/// `lyrics.kugou.com/download?fmt=krc` 返回 `{content: base64(加密KRC)}`。加密KRC =
/// 4 字节 magic `"krc1"` + zlib压缩数据逐字节 XOR 固定 16 字节 key。解密：base64 →
/// 去 magic → XOR → zlib inflate → UTF-8。key 是酷狗公开固定值。
const List<int> _krcKey = <int>[
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, //
  0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

/// 解密 KRC content（base64）→ KRC 明文（`[行起,行长]<字偏移,字长,0>字…`，字偏移
/// 相对行首）。任何环节失败返回 null（调用方回退行级 LRC）。
String? kugouDecryptKrc(String base64Content) {
  final String b = base64Content.trim();
  if (b.length < 8) return null;
  try {
    final Uint8List raw = base64.decode(b);
    // magic 'krc1' = 0x6b 0x72 0x63 0x31
    if (raw.length <= 4 ||
        raw[0] != 0x6b ||
        raw[1] != 0x72 ||
        raw[2] != 0x63 ||
        raw[3] != 0x31) {
      return null;
    }
    final Uint8List enc = Uint8List(raw.length - 4);
    for (int i = 0; i < enc.length; i++) {
      enc[i] = raw[i + 4] ^ _krcKey[i & 15];
    }
    final List<int> inflated = zlib.decode(enc);
    if (inflated.isEmpty) return null;
    return utf8.decode(inflated, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

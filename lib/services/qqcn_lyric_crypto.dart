import 'dart:io' show zlib;
import 'dart:convert' show utf8;
import 'dart:typed_data';

/// QRC (QQ音乐逐字歌词) 解密。
///
/// QQ 的 QRC 密文是 hex 字符串，解密流水线（与官方 `QRCDesDecrypt` + native
/// `libdesdecrypt.so` 等价）：hex→字节 → 腾讯「buggy 三重 DES」逐 8 字节块解密 →
/// zlib inflate → UTF-8。DES 是魔改版（sbox 里带故意的 bug、只有 15+1 轮结构），
/// 必须逐字节复刻，不能用标准 DES 库。移植自公开验证实现 WXRIW/QQMusicDecoder。
///
/// 固定密钥（24 字节 = 3×8）。
final Uint8List _qqKey =
    Uint8List.fromList('!@#)(*\$%123ZXC!@!@#)(NHL'.codeUnits);

/// 解密一段 QRC hex 密文 → QRC 明文（`[ti:..][start,dur]字(s,d)字(s,d)…`）。
/// 任何环节失败返回 null（调用方回退行级 LRC）。
String? qqcnDecryptQrc(String hexOrNull) {
  final String hex = hexOrNull.trim();
  if (hex.isEmpty || hex.length % 2 != 0) return null;
  try {
    final Uint8List enc = _hexToBytes(hex);
    if (enc.isEmpty || enc.length % 8 != 0) return null;
    // 三重 DES 密钥编排（DECRYPT 模式）。
    final List<List<List<int>>> schedule = List<List<List<int>>>.generate(
      3,
      (_) => List<List<int>>.generate(16, (_) => List<int>.filled(6, 0)),
    );
    _tripleDesKeySetup(_qqKey, schedule, _decrypt);
    final Uint8List out = Uint8List(enc.length);
    final Uint8List block = Uint8List(8);
    final Uint8List temp = Uint8List(8);
    for (int i = 0; i < enc.length; i += 8) {
      for (int j = 0; j < 8; j++) {
        block[j] = enc[i + j];
      }
      _tripleDesCrypt(block, temp, schedule);
      for (int j = 0; j < 8; j++) {
        out[i + j] = temp[j];
      }
    }
    final List<int> inflated = zlib.decode(out);
    if (inflated.isEmpty) return null;
    return utf8.decode(inflated, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 「buggy 三重 DES」—— 逐字节移植自 WXRIW/QQMusicDecoder 的 DESHelper.cs。
// C# 的 uint 是 32 位无符号；Dart int 是 64 位，故凡可能溢出处 & 0xFFFFFFFF。
// sbox 中的 `10,10`(sbox4)/`8,15`(sbox2) 等是腾讯故意保留的 bug，必须原样。
// ---------------------------------------------------------------------------

const int _encrypt = 1;
const int _decrypt = 0;
const int _m32 = 0xFFFFFFFF;

int _bitnum(Uint8List a, int b, int c) =>
    ((((a[(b ~/ 32) * 4 + 3 - (b % 32) ~/ 8] >> (7 - (b % 8))) & 0x01)) << c) &
    _m32;

int _bitnumIntr(int a, int b, int c) =>
    (((a >> (31 - b)) & 0x00000001) << c) & 0xFF;

int _bitnumIntl(int a, int b, int c) => (((a << b) & 0x80000000) >> c) & _m32;

int _sboxbit(int a) => (a & 0x20) | ((a & 0x1f) >> 1) | ((a & 0x01) << 4);

const List<int> _sbox1 = <int>[
  14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, //
  0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
  4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
  15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
];
const List<int> _sbox2 = <int>[
  15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, //
  3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
  0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
  13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
];
const List<int> _sbox3 = <int>[
  10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, //
  13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
  13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
  1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
];
const List<int> _sbox4 = <int>[
  7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, //
  13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
  10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
  3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
];
const List<int> _sbox5 = <int>[
  2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, //
  14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
  4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
  11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
];
const List<int> _sbox6 = <int>[
  12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, //
  10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
  9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
  4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
];
const List<int> _sbox7 = <int>[
  4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, //
  13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
  1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
  6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
];
const List<int> _sbox8 = <int>[
  13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, //
  1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
  7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
  2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
];

void _keySchedule(Uint8List key, List<List<int>> schedule, int mode) {
  const List<int> keyRndShift = <int>[
    1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1 //
  ];
  const List<int> keyPermC = <int>[
    56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, //
    9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35
  ];
  const List<int> keyPermD = <int>[
    62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, //
    13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3
  ];
  const List<int> keyCompression = <int>[
    13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, //
    22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
    40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47,
    43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31
  ];

  int c = 0, d = 0;
  for (int i = 0, j = 31; i < 28; ++i, --j) {
    c |= _bitnum(key, keyPermC[i], j);
  }
  for (int i = 0, j = 31; i < 28; ++i, --j) {
    d |= _bitnum(key, keyPermD[i], j);
  }
  c &= _m32;
  d &= _m32;

  for (int i = 0; i < 16; ++i) {
    c = ((c << keyRndShift[i]) | (c >> (28 - keyRndShift[i]))) & 0xfffffff0;
    d = ((d << keyRndShift[i]) | (d >> (28 - keyRndShift[i]))) & 0xfffffff0;
    final int toGen = mode == _decrypt ? 15 - i : i;
    for (int j = 0; j < 6; ++j) {
      schedule[toGen][j] = 0;
    }
    int j = 0;
    for (; j < 24; ++j) {
      schedule[toGen][j ~/ 8] |= _bitnumIntr(c, keyCompression[j], 7 - (j % 8));
    }
    for (; j < 48; ++j) {
      schedule[toGen][j ~/ 8] |=
          _bitnumIntr(d, keyCompression[j] - 27, 7 - (j % 8));
    }
  }
}

void _ip(List<int> state, Uint8List input) {
  state[0] = (_bitnum(input, 57, 31) |
          _bitnum(input, 49, 30) |
          _bitnum(input, 41, 29) |
          _bitnum(input, 33, 28) |
          _bitnum(input, 25, 27) |
          _bitnum(input, 17, 26) |
          _bitnum(input, 9, 25) |
          _bitnum(input, 1, 24) |
          _bitnum(input, 59, 23) |
          _bitnum(input, 51, 22) |
          _bitnum(input, 43, 21) |
          _bitnum(input, 35, 20) |
          _bitnum(input, 27, 19) |
          _bitnum(input, 19, 18) |
          _bitnum(input, 11, 17) |
          _bitnum(input, 3, 16) |
          _bitnum(input, 61, 15) |
          _bitnum(input, 53, 14) |
          _bitnum(input, 45, 13) |
          _bitnum(input, 37, 12) |
          _bitnum(input, 29, 11) |
          _bitnum(input, 21, 10) |
          _bitnum(input, 13, 9) |
          _bitnum(input, 5, 8) |
          _bitnum(input, 63, 7) |
          _bitnum(input, 55, 6) |
          _bitnum(input, 47, 5) |
          _bitnum(input, 39, 4) |
          _bitnum(input, 31, 3) |
          _bitnum(input, 23, 2) |
          _bitnum(input, 15, 1) |
          _bitnum(input, 7, 0)) &
      _m32;
  state[1] = (_bitnum(input, 56, 31) |
          _bitnum(input, 48, 30) |
          _bitnum(input, 40, 29) |
          _bitnum(input, 32, 28) |
          _bitnum(input, 24, 27) |
          _bitnum(input, 16, 26) |
          _bitnum(input, 8, 25) |
          _bitnum(input, 0, 24) |
          _bitnum(input, 58, 23) |
          _bitnum(input, 50, 22) |
          _bitnum(input, 42, 21) |
          _bitnum(input, 34, 20) |
          _bitnum(input, 26, 19) |
          _bitnum(input, 18, 18) |
          _bitnum(input, 10, 17) |
          _bitnum(input, 2, 16) |
          _bitnum(input, 60, 15) |
          _bitnum(input, 52, 14) |
          _bitnum(input, 44, 13) |
          _bitnum(input, 36, 12) |
          _bitnum(input, 28, 11) |
          _bitnum(input, 20, 10) |
          _bitnum(input, 12, 9) |
          _bitnum(input, 4, 8) |
          _bitnum(input, 62, 7) |
          _bitnum(input, 54, 6) |
          _bitnum(input, 46, 5) |
          _bitnum(input, 38, 4) |
          _bitnum(input, 30, 3) |
          _bitnum(input, 22, 2) |
          _bitnum(input, 14, 1) |
          _bitnum(input, 6, 0)) &
      _m32;
}

void _invIp(List<int> state, Uint8List output) {
  final int s0 = state[0], s1 = state[1];
  output[3] = _bitnumIntr(s1, 7, 7) |
      _bitnumIntr(s0, 7, 6) |
      _bitnumIntr(s1, 15, 5) |
      _bitnumIntr(s0, 15, 4) |
      _bitnumIntr(s1, 23, 3) |
      _bitnumIntr(s0, 23, 2) |
      _bitnumIntr(s1, 31, 1) |
      _bitnumIntr(s0, 31, 0);
  output[2] = _bitnumIntr(s1, 6, 7) |
      _bitnumIntr(s0, 6, 6) |
      _bitnumIntr(s1, 14, 5) |
      _bitnumIntr(s0, 14, 4) |
      _bitnumIntr(s1, 22, 3) |
      _bitnumIntr(s0, 22, 2) |
      _bitnumIntr(s1, 30, 1) |
      _bitnumIntr(s0, 30, 0);
  output[1] = _bitnumIntr(s1, 5, 7) |
      _bitnumIntr(s0, 5, 6) |
      _bitnumIntr(s1, 13, 5) |
      _bitnumIntr(s0, 13, 4) |
      _bitnumIntr(s1, 21, 3) |
      _bitnumIntr(s0, 21, 2) |
      _bitnumIntr(s1, 29, 1) |
      _bitnumIntr(s0, 29, 0);
  output[0] = _bitnumIntr(s1, 4, 7) |
      _bitnumIntr(s0, 4, 6) |
      _bitnumIntr(s1, 12, 5) |
      _bitnumIntr(s0, 12, 4) |
      _bitnumIntr(s1, 20, 3) |
      _bitnumIntr(s0, 20, 2) |
      _bitnumIntr(s1, 28, 1) |
      _bitnumIntr(s0, 28, 0);
  output[7] = _bitnumIntr(s1, 3, 7) |
      _bitnumIntr(s0, 3, 6) |
      _bitnumIntr(s1, 11, 5) |
      _bitnumIntr(s0, 11, 4) |
      _bitnumIntr(s1, 19, 3) |
      _bitnumIntr(s0, 19, 2) |
      _bitnumIntr(s1, 27, 1) |
      _bitnumIntr(s0, 27, 0);
  output[6] = _bitnumIntr(s1, 2, 7) |
      _bitnumIntr(s0, 2, 6) |
      _bitnumIntr(s1, 10, 5) |
      _bitnumIntr(s0, 10, 4) |
      _bitnumIntr(s1, 18, 3) |
      _bitnumIntr(s0, 18, 2) |
      _bitnumIntr(s1, 26, 1) |
      _bitnumIntr(s0, 26, 0);
  output[5] = _bitnumIntr(s1, 1, 7) |
      _bitnumIntr(s0, 1, 6) |
      _bitnumIntr(s1, 9, 5) |
      _bitnumIntr(s0, 9, 4) |
      _bitnumIntr(s1, 17, 3) |
      _bitnumIntr(s0, 17, 2) |
      _bitnumIntr(s1, 25, 1) |
      _bitnumIntr(s0, 25, 0);
  output[4] = _bitnumIntr(s1, 0, 7) |
      _bitnumIntr(s0, 0, 6) |
      _bitnumIntr(s1, 8, 5) |
      _bitnumIntr(s0, 8, 4) |
      _bitnumIntr(s1, 16, 3) |
      _bitnumIntr(s0, 16, 2) |
      _bitnumIntr(s1, 24, 1) |
      _bitnumIntr(s0, 24, 0);
}

int _f(int state, List<int> key) {
  state &= _m32;
  final Uint8List l = Uint8List(6);
  int t1 = (_bitnumIntl(state, 31, 0) |
          ((state & 0xf0000000) >> 1) |
          _bitnumIntl(state, 4, 5) |
          _bitnumIntl(state, 3, 6) |
          ((state & 0x0f000000) >> 3) |
          _bitnumIntl(state, 8, 11) |
          _bitnumIntl(state, 7, 12) |
          ((state & 0x00f00000) >> 5) |
          _bitnumIntl(state, 12, 17) |
          _bitnumIntl(state, 11, 18) |
          ((state & 0x000f0000) >> 7) |
          _bitnumIntl(state, 16, 23)) &
      _m32;
  int t2 = (_bitnumIntl(state, 15, 0) |
          ((state & 0x0000f000) << 15) |
          _bitnumIntl(state, 20, 5) |
          _bitnumIntl(state, 19, 6) |
          ((state & 0x00000f00) << 13) |
          _bitnumIntl(state, 24, 11) |
          _bitnumIntl(state, 23, 12) |
          ((state & 0x000000f0) << 11) |
          _bitnumIntl(state, 28, 17) |
          _bitnumIntl(state, 27, 18) |
          ((state & 0x0000000f) << 9) |
          _bitnumIntl(state, 0, 23)) &
      _m32;
  l[0] = (t1 >> 24) & 0xff;
  l[1] = (t1 >> 16) & 0xff;
  l[2] = (t1 >> 8) & 0xff;
  l[3] = (t2 >> 24) & 0xff;
  l[4] = (t2 >> 16) & 0xff;
  l[5] = (t2 >> 8) & 0xff;
  for (int i = 0; i < 6; i++) {
    l[i] ^= key[i];
  }
  int s = ((_sbox1[_sboxbit(l[0] >> 2)] << 28) |
          (_sbox2[_sboxbit(((l[0] & 0x03) << 4) | (l[1] >> 4))] << 24) |
          (_sbox3[_sboxbit(((l[1] & 0x0f) << 2) | (l[2] >> 6))] << 20) |
          (_sbox4[_sboxbit(l[2] & 0x3f)] << 16) |
          (_sbox5[_sboxbit(l[3] >> 2)] << 12) |
          (_sbox6[_sboxbit(((l[3] & 0x03) << 4) | (l[4] >> 4))] << 8) |
          (_sbox7[_sboxbit(((l[4] & 0x0f) << 2) | (l[5] >> 6))] << 4) |
          _sbox8[_sboxbit(l[5] & 0x3f)]) &
      _m32;
  s = (_bitnumIntl(s, 15, 0) |
          _bitnumIntl(s, 6, 1) |
          _bitnumIntl(s, 19, 2) |
          _bitnumIntl(s, 20, 3) |
          _bitnumIntl(s, 28, 4) |
          _bitnumIntl(s, 11, 5) |
          _bitnumIntl(s, 27, 6) |
          _bitnumIntl(s, 16, 7) |
          _bitnumIntl(s, 0, 8) |
          _bitnumIntl(s, 14, 9) |
          _bitnumIntl(s, 22, 10) |
          _bitnumIntl(s, 25, 11) |
          _bitnumIntl(s, 4, 12) |
          _bitnumIntl(s, 17, 13) |
          _bitnumIntl(s, 30, 14) |
          _bitnumIntl(s, 9, 15) |
          _bitnumIntl(s, 1, 16) |
          _bitnumIntl(s, 7, 17) |
          _bitnumIntl(s, 23, 18) |
          _bitnumIntl(s, 13, 19) |
          _bitnumIntl(s, 31, 20) |
          _bitnumIntl(s, 26, 21) |
          _bitnumIntl(s, 2, 22) |
          _bitnumIntl(s, 8, 23) |
          _bitnumIntl(s, 18, 24) |
          _bitnumIntl(s, 12, 25) |
          _bitnumIntl(s, 29, 26) |
          _bitnumIntl(s, 5, 27) |
          _bitnumIntl(s, 21, 28) |
          _bitnumIntl(s, 10, 29) |
          _bitnumIntl(s, 3, 30) |
          _bitnumIntl(s, 24, 31)) &
      _m32;
  return s;
}

void _crypt(Uint8List input, Uint8List output, List<List<int>> key) {
  final List<int> state = <int>[0, 0];
  _ip(state, input);
  for (int idx = 0; idx < 15; ++idx) {
    final int t = state[1];
    state[1] = (_f(state[1], key[idx]) ^ state[0]) & _m32;
    state[0] = t;
  }
  state[0] = (_f(state[1], key[15]) ^ state[0]) & _m32;
  _invIp(state, output);
}

void _tripleDesKeySetup(
    Uint8List key, List<List<List<int>>> schedule, int mode) {
  final Uint8List k0 = key.sublist(0, 8);
  final Uint8List k1 = key.sublist(8, 16);
  final Uint8List k2 = key.sublist(16, 24);
  if (mode == _encrypt) {
    _keySchedule(k0, schedule[0], _encrypt);
    _keySchedule(k1, schedule[1], _decrypt);
    _keySchedule(k2, schedule[2], _encrypt);
  } else {
    _keySchedule(k0, schedule[2], _decrypt);
    _keySchedule(k1, schedule[1], _encrypt);
    _keySchedule(k2, schedule[0], _decrypt);
  }
}

void _tripleDesCrypt(
    Uint8List input, Uint8List output, List<List<List<int>>> key) {
  _crypt(input, output, key[0]);
  _crypt(output, output, key[1]);
  _crypt(output, output, key[2]);
}

Uint8List _hexToBytes(String hex) {
  final int n = hex.length ~/ 2;
  final Uint8List out = Uint8List(n);
  for (int i = 0; i < n; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

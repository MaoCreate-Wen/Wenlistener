/// A signed-in Kugou (酷狗) account. Kugou's play API (`play/songinfo`)
/// authenticates purely from the `token` + `userid` query pair (no cookies, no
/// AES/RSA hand-off) — the same `token` the QR poll hands back on confirmation
/// (verified: the poll's `data.token` is byte-identical to the web `t` cookie the
/// reference login saves). So an account is just this small credential blob;
/// injecting it into [KugouApi] unlocks full-song playback that's otherwise
/// gated behind `err 30020`.
class KugouAccount {
  /// `KugooID` — the numeric user id (sent as `userid`).
  final String userId;

  /// The auth token (sent as `token`; == the web `t` cookie).
  final String token;

  final String nickname;

  /// Avatar URL (Kugou `pic`), already https-normalized. Null when absent.
  final String? avatarUrl;

  /// Kugou VIP tier (0 = none). Best-effort; the QR flow may not report it.
  final int vipType;

  const KugouAccount({
    required this.userId,
    required this.token,
    this.nickname = '',
    this.avatarUrl,
    this.vipType = 0,
  });

  bool get isVip => vipType > 0;

  /// Whether this credential can actually authenticate a play request.
  bool get isValid => userId.isNotEmpty && token.isNotEmpty;

  KugouAccount copyWith({String? nickname, String? avatarUrl, int? vipType}) =>
      KugouAccount(
        userId: userId,
        token: token,
        nickname: nickname ?? this.nickname,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        vipType: vipType ?? this.vipType,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        'token': token,
        'nickname': nickname,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
        'vipType': vipType,
      };

  factory KugouAccount.fromJson(Map<String, dynamic> j) {
    final dynamic pic = j['avatarUrl'];
    return KugouAccount(
      userId: (j['userId'] ?? '').toString(),
      token: (j['token'] ?? '').toString(),
      nickname: (j['nickname'] ?? '').toString(),
      avatarUrl: (pic is String && pic.isNotEmpty) ? pic : null,
      vipType: _int(j['vipType']),
    );
  }
}

/// Result of creating a Kugou QR-login session (`/v2/qrcode`).
class KugouQrCreate {
  /// The dynamic qrcode id, polled by [KugouApi.qrPoll].
  final String qrcode;

  /// A ready-to-render `data:image/png;base64,…` of the scannable QR (the server
  /// draws it for us — no client-side QR encoder needed).
  final String imageDataUrl;

  const KugouQrCreate({required this.qrcode, required this.imageDataUrl});
}

/// Kugou QR-login lifecycle, from the poll's `data.status`.
enum KugouQrStatus { waiting, scanned, confirmed, expired, unknown }

/// Result of one Kugou QR poll (`/v2/get_userinfo_qrcode`). On
/// [KugouQrStatus.confirmed] the [account] carries the token/userid to inject.
class KugouQrPoll {
  final KugouQrStatus status;
  final KugouAccount? account;

  const KugouQrPoll({required this.status, this.account});

  /// Maps the nested `data.status` (1 waiting, 2 scanned, 4 confirmed, 0 expired).
  static KugouQrStatus statusFromData(int dataStatus) {
    switch (dataStatus) {
      case 1:
        return KugouQrStatus.waiting;
      case 2:
        return KugouQrStatus.scanned;
      case 4:
        return KugouQrStatus.confirmed;
      case 0:
        return KugouQrStatus.expired;
      default:
        return KugouQrStatus.unknown;
    }
  }
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

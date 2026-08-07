/// A signed-in Kugougn (酷狗) account. The 概念版 (FreeListen / Lite) Android backend
/// authenticates every play/search request purely from the `token` + `userid`
/// pair folded into the signed query — the exact credential the SMS
/// verify-code login (`/v7/login_by_verifycode`) hands back. So an account is
/// just this small blob; injecting it into [KugougnApi] unlocks full playback and
/// the account's `user_labels`/VIP state.
class KugougnAccount {
  /// The numeric Kugougn user id (sent as `userid`).
  final String userId;

  /// The auth token (sent as `token`).
  final String token;

  final String nickname;

  /// Avatar URL (Kugougn `pic`), already https-normalized. Null when absent.
  final String? avatarUrl;

  /// Kugougn VIP tier (0 = none). Best-effort from the login response.
  final int vipType;

  const KugougnAccount({
    required this.userId,
    required this.token,
    this.nickname = '',
    this.avatarUrl,
    this.vipType = 0,
  });

  bool get isVip => vipType > 0;

  /// Whether this credential can actually authenticate a request.
  bool get isValid => userId.isNotEmpty && token.isNotEmpty;

  KugougnAccount copyWith({String? nickname, String? avatarUrl, int? vipType}) =>
      KugougnAccount(
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

  factory KugougnAccount.fromJson(Map<String, dynamic> j) {
    final dynamic pic = j['avatarUrl'];
    return KugougnAccount(
      userId: (j['userId'] ?? '').toString(),
      token: (j['token'] ?? '').toString(),
      nickname: (j['nickname'] ?? '').toString(),
      avatarUrl: (pic is String && pic.isNotEmpty) ? pic : null,
      vipType: _int(j['vipType']),
    );
  }
}

/// Lifecycle of the Kugougn phone-number + SMS-verify-code login, driven by
/// [KugougnAuthProvider]. Replaces the old QR flow (the 概念版 backend has no
/// scannable-QR endpoint — it logs in with a mobile code).
enum KugougnLoginStage {
  /// Nothing in progress (initial / after reset).
  idle,

  /// A `send_mobile_code` request is in flight.
  sendingCode,

  /// The SMS code was sent; awaiting the user's code entry + submit.
  codeSent,

  /// A `login_by_verifycode` request is in flight.
  loggingIn,

  /// Login succeeded (an account was added + made active).
  success,

  /// The last step failed; see [KugougnAuthProvider.loginError].
  error,
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

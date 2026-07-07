/// A saved account for a COOKIE-based source (网易云 / QQ音乐). Unlike Kugou (a
/// token pair), these logins live entirely in a cookie jar — so an account is a
/// full snapshot of that jar ([cookies]) plus the profile fields for the UI.
/// Switching accounts restores the snapshot into the live jar.
class CookieAccount {
  /// Stable account id — the Netease uid / QQ uin.
  final String id;
  final String nickname;
  final String? avatarUrl;

  /// Membership tier (0 = none) — Netease 黑胶 vipType / QQ 绿钻 (best-effort).
  final int vipType;

  /// The full cookie snapshot (name→value) captured at login; restored verbatim
  /// into the jar when this account is made active.
  final Map<String, String> cookies;

  const CookieAccount({
    required this.id,
    this.nickname = '',
    this.avatarUrl,
    this.vipType = 0,
    this.cookies = const <String, String>{},
  });

  bool get isVip => vipType > 0;

  CookieAccount copyWith({
    String? nickname,
    String? avatarUrl,
    int? vipType,
    Map<String, String>? cookies,
  }) =>
      CookieAccount(
        id: id,
        nickname: nickname ?? this.nickname,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        vipType: vipType ?? this.vipType,
        cookies: cookies ?? this.cookies,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'nickname': nickname,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
        'vipType': vipType,
        'cookies': cookies,
      };

  factory CookieAccount.fromJson(Map<String, dynamic> j) {
    final dynamic ck = j['cookies'];
    final Map<String, String> cookies = <String, String>{};
    if (ck is Map) {
      ck.forEach((dynamic k, dynamic v) => cookies[k.toString()] = v.toString());
    }
    final dynamic pic = j['avatarUrl'];
    return CookieAccount(
      id: (j['id'] ?? '').toString(),
      nickname: (j['nickname'] ?? '').toString(),
      avatarUrl: (pic is String && pic.isNotEmpty) ? pic : null,
      vipType: (j['vipType'] is num) ? (j['vipType'] as num).toInt() : 0,
      cookies: cookies,
    );
  }
}

import 'dart:typed_data';

/// QQ Music supports two scan-login methods (QQMUSIC_API.md#登录认证).
enum QqcnLoginMethod { qq, wechat }

/// QR-login lifecycle (mapped from the QQ `ptuiCB` code / WeChat `wx_errcode`).
enum QqcnQrStatus { waiting, scanned, confirmed, expired, canceled, unknown }

/// A live QR session: the scannable PNG plus the key used to poll it (`qrsig`
/// for QQ, `uuid` for WeChat).
class QqcnQrSession {
  final Uint8List image;
  final String pollKey;
  const QqcnQrSession({required this.image, required this.pollKey});
}

/// One poll result. On [QqcnQrStatus.confirmed] the [payload] carries what
/// [completeLogin] needs to finish: the QQ `redirect_url`, or the WeChat `code`.
class QqcnQrPoll {
  final QqcnQrStatus status;
  final String? payload;
  const QqcnQrPoll({required this.status, this.payload});
}

/// The signed-in QQ account (best-effort profile after the session lands).
class QqcnAccount {
  final String uin;
  final String nickname;
  final String? avatarUrl;
  final bool isVip;

  const QqcnAccount({
    required this.uin,
    this.nickname = '',
    this.avatarUrl,
    this.isVip = false,
  });
}

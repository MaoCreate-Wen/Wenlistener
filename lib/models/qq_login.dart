import 'dart:typed_data';

/// QQ Music supports two scan-login methods (QQMUSIC_API.md#登录认证).
enum QqLoginMethod { qq, wechat }

/// QR-login lifecycle (mapped from the QQ `ptuiCB` code / WeChat `wx_errcode`).
enum QqQrStatus { waiting, scanned, confirmed, expired, canceled, unknown }

/// A live QR session: the scannable PNG plus the key used to poll it (`qrsig`
/// for QQ, `uuid` for WeChat).
class QqQrSession {
  final Uint8List image;
  final String pollKey;
  const QqQrSession({required this.image, required this.pollKey});
}

/// One poll result. On [QqQrStatus.confirmed] the [payload] carries what
/// [completeLogin] needs to finish: the QQ `redirect_url`, or the WeChat `code`.
class QqQrPoll {
  final QqQrStatus status;
  final String? payload;
  const QqQrPoll({required this.status, this.payload});
}

/// The signed-in QQ account (best-effort profile after the session lands).
class QqAccount {
  final String uin;
  final String nickname;
  final String? avatarUrl;
  final bool isVip;

  const QqAccount({
    required this.uin,
    this.nickname = '',
    this.avatarUrl,
    this.isVip = false,
  });
}

/// Result of creating a QR-login session (`/login/qrcode/unikey`).
class QrCreateResult {
  /// The unikey used when polling.
  final String uniKey;

  /// The `scanlogin` URL the user scans (includes codekey + chainId).
  final String qrContent;

  const QrCreateResult({required this.uniKey, required this.qrContent});
}

/// QR-login lifecycle state (derived from the poll `code`).
enum QrStatus { expired, waitingScan, scanned, authorized, invalidated, unknown }

/// Result of one poll (`/login/qrcode/client/login`). On [QrStatus.authorized]
/// (code 803) the auth cookies arrive via Set-Cookie, captured into
/// [musicU] / [csrf].
class QrPollResult {
  final QrStatus status;
  final int code;
  final String? musicU;
  final String? csrf;
  final String? message;

  const QrPollResult({
    required this.status,
    required this.code,
    this.musicU,
    this.csrf,
    this.message,
  });

  /// Maps a poll `code` to a [QrStatus]
  /// (800 expired, 801 waiting, 802 scanned, 803 authorized, 860 invalidated).
  static QrStatus statusFromCode(int code) {
    switch (code) {
      case 800:
        return QrStatus.expired;
      case 801:
        return QrStatus.waitingScan;
      case 802:
        return QrStatus.scanned;
      case 803:
        return QrStatus.authorized;
      case 860:
        return QrStatus.invalidated;
      default:
        return QrStatus.unknown;
    }
  }
}

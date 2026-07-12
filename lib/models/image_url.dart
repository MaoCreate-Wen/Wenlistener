/// Normalizes a Netease CDN image URL to HTTPS.
///
/// Netease returns cover/avatar URLs as `http://p?.music.126.net/...`. Android
/// (cleartext blocked by default since targetSdk 28) and iOS (ATS) refuse plain
/// HTTP, so the images silently fall back to placeholders. The CDN serves the
/// identical asset over TLS, so upgrading the scheme fixes loading everywhere
/// (ArtworkImage, palette extraction, blurred art background).
///
/// Returns null for null/empty/non-String input so callers can keep a nullable
/// field.
String? httpsImageUrl(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  if (raw.startsWith('http://')) {
    return 'https://${raw.substring('http://'.length)}';
  }
  return raw;
}

/// Headers every Netease image request must carry. The CDN (`p?.music.126.net`)
/// returns 403 to the bare `Dart/x.y` User-Agent that cached_network_image's
/// HttpClient sends by default — it gates on a browser UA + Referer. Without
/// these, all covers/art silently fall back to placeholders.
const Map<String, String> kNeteaseImageHeaders = <String, String>{
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Referer': 'https://music.163.com/',
};

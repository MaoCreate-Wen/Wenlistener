import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/models/search_result.dart';
import 'package:wenlistener/services/cookie_store.dart';
import 'package:wenlistener/services/dio_factory.dart';
import 'package:wenlistener/services/netease_api.dart';
import 'package:wenlistener/services/netease_crypto.dart';

/// Live end-to-end smoke test against music.163.com. Skipped by default so
/// offline `flutter test` stays green. Enable with:
///   flutter test --dart-define=LIVE_NETEASE=true
const bool _runLive = bool.fromEnvironment('LIVE_NETEASE');

void main() {
  test(
    'anonymous search("周杰伦") returns songs',
    () async {
      final CookieStore cookies = CookieStore(jar: CookieJar());
      final Dio dio = DioFactory.create(cookies);
      final NeteaseApi api = NeteaseApi(
        dio: dio,
        crypto: const NeteaseCrypto(),
        cookies: cookies,
      );

      final SearchResult result = await api.search(keyword: '周杰伦');
      expect(result.songs, isNotEmpty,
          reason: 'weapi search should return songs anonymously');
      expect(result.songs.first.name, isNotEmpty);
      expect(result.songs.first.artistNames, isNotEmpty);
    },
    skip: _runLive
        ? false
        : 'live network test; run with --dart-define=LIVE_NETEASE=true',
  );
}

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import 'cookie_store.dart';
import 'netease_endpoints.dart';

/// Injects the static headers every weapi request needs.
///
/// weapi/login can reject a bare `Dart/x.y` agent, so we send a browser-like
/// User-Agent plus the `Origin` / `Referer: music.163.com` pair the working
/// reference (`login.py`) uses. `putIfAbsent` keeps per-request overrides intact.
class WeapiInterceptor extends Interceptor {
  /// Browser UA copied from the working reference `login.py` (Edge on Win64).
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0';

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) {
    options.headers.putIfAbsent('origin', () => 'https://music.163.com');
    options.headers.putIfAbsent('referer', () => 'https://music.163.com/');
    options.headers.putIfAbsent('user-agent', () => _userAgent);
    options.headers.putIfAbsent('accept', () => '*/*');
    options.headers.putIfAbsent('accept-language', () => 'zh-CN,zh;q=0.9');
    options.headers.putIfAbsent('x-os', () => 'web');
    options.headers.putIfAbsent('nm-gcore-status', () => '1');
    handler.next(options);
  }
}

/// Builds the shared [Dio] for the Netease layer: cookie persistence +
/// weapi headers.
class DioFactory {
  DioFactory._();

  static Dio create(CookieStore store) {
    final Dio dio = Dio(
      BaseOptions(
        baseUrl: NeteaseEndpoints.base,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 15),
        responseType: ResponseType.json,
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (int? status) => status != null && status < 500,
      ),
    );
    dio.interceptors.add(CookieManager(store.jar));
    dio.interceptors.add(WeapiInterceptor());
    return dio;
  }

  /// Bare [Dio] for direct binary resource downloads (`ResourceCache`'s cover
  /// fetches): no cookie jar, no weapi headers/base-url, strict 2xx, redirects
  /// followed. Callers pass per-request headers (e.g. `kNeteaseImageHeaders`).
  static Dio createPlain() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (int? status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
}

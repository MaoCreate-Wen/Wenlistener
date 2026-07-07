import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../services/kuwo_api.dart';
import '../services/kuwo_cookie_store.dart';
import '../services/music_api_router.dart';

enum KuwoLoginStep { idle, loadingCaptcha, waitingInput, loggingIn, done, failed }

/// Manages Kuwo (酷我音乐) password+captcha login state.
class KuwoAuthProvider extends ChangeNotifier {
  final KuwoApi api;
  final KuwoCookieStore cookies;
  final MusicApiRouter router;

  KuwoAuthProvider({
    required this.api,
    required this.cookies,
    required this.router,
  }) {
    unawaited(_init());
  }

  KuwoLoginStep _step = KuwoLoginStep.idle;
  Uint8List? _captchaBytes;
  String _captchaToken = '';
  String? _errorMsg;

  bool get isLoggedIn => cookies.isLoggedIn;
  KuwoLoginStep get step => _step;
  Uint8List? get captchaBytes => _captchaBytes;
  String? get errorMsg => _errorMsg;

  Future<void> _init() async {
    await cookies.load();
    notifyListeners();
  }

  /// Loads a fresh captcha image. Call when opening the login page.
  Future<void> loadCaptcha() async {
    _step = KuwoLoginStep.loadingCaptcha;
    _errorMsg = null;
    notifyListeners();
    try {
      final Map<String, String> c = await api.getCaptcha();
      final String b64 = c['imgBase64'] ?? '';
      _captchaToken = c['token'] ?? '';
      // Strip data-URL prefix if present.
      final String raw =
          b64.contains(',') ? b64.split(',').last : b64;
      _captchaBytes = base64Decode(raw);
      _step = KuwoLoginStep.waitingInput;
    } catch (e) {
      _step = KuwoLoginStep.failed;
      _errorMsg = '验证码加载失败：$e';
    }
    notifyListeners();
  }

  Future<bool> login({
    required String username,
    required String password,
    required String verifyCode,
  }) async {
    _step = KuwoLoginStep.loggingIn;
    _errorMsg = null;
    notifyListeners();
    try {
      final bool ok = await api.login(
        username: username,
        password: password,
        verifyCode: verifyCode,
        verifyCodeToken: _captchaToken,
      );
      if (ok) {
        _step = KuwoLoginStep.done;
        router.refresh();
        notifyListeners();
        return true;
      }
      _step = KuwoLoginStep.failed;
      _errorMsg = '登录失败，请检查账号密码或验证码';
      notifyListeners();
      return false;
    } catch (e) {
      _step = KuwoLoginStep.failed;
      _errorMsg = '登录错误：$e';
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    await api.logout();
    _step = KuwoLoginStep.idle;
    notifyListeners();
    router.refresh();
  }

  void reset() {
    _step = KuwoLoginStep.idle;
    _captchaBytes = null;
    _captchaToken = '';
    _errorMsg = null;
    notifyListeners();
  }
}

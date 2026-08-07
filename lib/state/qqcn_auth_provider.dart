import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../models/cookie_account.dart';
import '../models/qqcn_login.dart';
import '../services/cookie_account_store.dart';
import '../services/music_api_router.dart';
import '../services/qqcn_api.dart';
import '../services/qqcn_cookie_store.dart';

/// QR-login state machine for QQ Music, supporting BOTH scan methods (微信 / QQ,
/// per QQMUSIC_API.md). Mirrors the Netease [AuthProvider]: create a session,
/// poll every 2s (300s timeout), and on confirmation finish the OAuth handoff
/// ([QqcnApi.completeLogin]) so the `qm_keyst` session cookie lands — then
/// `router.refresh()` reloads the (now non-empty) QQ feeds. Cookie-based single
/// account (the jar is the persistence), like Netease.
///
/// Background-resilient: the user leaves the app to scan, so an on-resume
/// [pollNow] catches a confirmation that arrived while backgrounded.
class QqcnAuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  final QqcnApi api;
  final QqcnCookieStore cookies;
  final MusicApiRouter router;

  QqcnAuthProvider({
    required this.api,
    required this.cookies,
    required this.router,
    CookieAccountStore? accountStore,
  }) : _store = accountStore ?? const CookieAccountStore('qqcn_accounts.json') {
    _isLoggedIn = cookies.isLoggedIn;
    // Drop the session when a server-side verify confirms it's expired.
    api.onSessionExpired = _handleSessionExpired;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_init());
  }

  /// Persisted multi-account set — the live jar holds the ACTIVE account's
  /// cookies; each saved account is a full snapshot restored on switch.
  final CookieAccountStore _store;
  List<CookieAccount> _accounts = <CookieAccount>[];
  String? _activeId;

  Future<void> _init() async {
    final ({List<CookieAccount> accounts, String? activeId}) data =
        await _store.load();
    _accounts = data.accounts;
    _activeId = data.activeId;
    notifyListeners();
    if (_isLoggedIn) {
      await _refreshAccount();
      // Validate the restored session against the server (an expired qm_keyst
      // otherwise strands the app "logged in" while every authed call fails).
      unawaited(api.verifyLoginState());
    }
  }

  /// Guards [_handleSessionExpired] so a burst of failing calls fires one cycle.
  bool _handlingExpiry = false;

  /// Handles a confirmed session expiry from [QqcnApi.verifyLoginState]. Drops the
  /// dead account (falling back to the next saved one, or logged-out) so the
  /// settings account section re-shows the QR prompt. QQ has no documented
  /// silent-refresh endpoint, so recovery is a fresh scan.
  Future<void> _handleSessionExpired() async {
    if (_handlingExpiry || !_isLoggedIn) return;
    _handlingExpiry = true;
    try {
      final String? id = _activeId;
      if (id != null) {
        await removeAccount(id); // drops active, falls back or logs out
      } else {
        await api.logout();
        _isLoggedIn = false;
        _account = null;
        router.refresh();
        notifyListeners();
      }
    } finally {
      _handlingExpiry = false;
    }
  }

  static const Duration _interval = Duration(seconds: 2);
  static const Duration _timeout = Duration(seconds: 300);

  bool _isLoggedIn = false;
  QqcnAccount? _account;
  QqcnLoginMethod _method = QqcnLoginMethod.qq;
  Uint8List? _qrImage;
  QqcnQrStatus _qrStatus = QqcnQrStatus.unknown;
  bool _qrLoading = false;
  bool _polling = false;
  String? _pollKey;
  bool _pollInFlight = false;
  // True while finishing the OAuth handoff after a scan-confirm — the scan is
  // done but the session (qm_keyst) isn't landed yet, so we must NOT claim "登录成功".
  bool _finishing = false;
  // Bumped on every startLogin so a superseded session (e.g. the user toggled
  // 微信↔QQ mid-poll) can't clobber the new one from its own async tail.
  int _gen = 0;

  bool get isLoggedIn => _isLoggedIn;
  QqcnAccount? get account => _account;
  QqcnLoginMethod get method => _method;
  Uint8List? get qrImage => _qrImage;
  QqcnQrStatus get qrStatus => _qrStatus;
  bool get qrLoading => _qrLoading;

  /// Scan confirmed, OAuth handoff in flight — show "正在登录…", not "登录成功".
  bool get finishingLogin => _finishing;

  /// All saved QQ accounts (multi-account); tap one to [switchAccount].
  List<CookieAccount> get accounts => _accounts;
  String? get activeId => _activeId;

  Future<void> _refreshAccount() async {
    try {
      final QqcnAccount? acct = await api.accountProfile();
      _isLoggedIn = cookies.isLoggedIn;
      _account = acct;
    } catch (_) {
      _isLoggedIn = cookies.isLoggedIn;
    }
    if (_isLoggedIn && _account != null) {
      await _captureActiveAccount();
    }
    notifyListeners();
  }

  /// Snapshots the live jar + profile into the saved-account set (keyed by uin).
  Future<void> _captureActiveAccount() async {
    final QqcnAccount? acct = _account;
    if (acct == null || acct.uin.isEmpty || acct.uin == '0') return;
    final Map<String, String> snap = await cookies.snapshot();
    // The Android session key is `authst` (the web `qm_keyst` equivalent) — only
    // capture a fully-landed session into the saved-account set.
    if ((snap['authst'] ?? '').isEmpty) return;
    final CookieAccount ca = CookieAccount(
      id: acct.uin,
      nickname: acct.nickname,
      avatarUrl: acct.avatarUrl,
      vipType: acct.isVip ? 1 : 0,
      cookies: snap,
    );
    _accounts = <CookieAccount>[
      for (final CookieAccount a in _accounts)
        if (a.id != acct.uin) a,
      ca,
    ];
    _activeId = acct.uin;
    await _store.save(_accounts, _activeId);
  }

  /// Switches the active QQ account: restores its cookie snapshot, re-reads the
  /// profile, reloads feeds. No-op if already active/unknown.
  Future<void> switchAccount(String id) async {
    if (id == _activeId) return;
    CookieAccount? target;
    for (final CookieAccount a in _accounts) {
      if (a.id == id) {
        target = a;
        break;
      }
    }
    if (target == null) return;
    await cookies.restore(target.cookies);
    _activeId = id;
    await _refreshAccount();
    router.refresh();
  }

  /// Removes a saved account; if active, falls back to the first remaining one or
  /// to logged-out when none are left.
  Future<void> removeAccount(String id) async {
    _accounts = _accounts.where((CookieAccount a) => a.id != id).toList();
    if (_activeId == id) {
      if (_accounts.isNotEmpty) {
        _activeId = _accounts.first.id;
        await _store.save(_accounts, _activeId);
        await cookies.restore(_accounts.first.cookies);
        await _refreshAccount();
        router.refresh();
        return;
      }
      _activeId = null;
      await cookies.clear();
      _isLoggedIn = false;
      _account = null;
      await _store.save(_accounts, _activeId);
      router.refresh();
      notifyListeners();
      return;
    }
    await _store.save(_accounts, _activeId);
    notifyListeners();
  }

  /// Starts (or restarts) a scan-login with [method] — a new call supersedes any
  /// in-flight session (via [_gen]), so toggling 微信↔QQ cleanly swaps the QR.
  Future<void> startLogin(QqcnLoginMethod method) async {
    final int myGen = ++_gen;
    _method = method;
    _polling = true;
    _qrLoading = true;
    _qrStatus = QqcnQrStatus.unknown;
    _qrImage = null;
    notifyListeners();
    try {
      final QqcnQrSession session = await api.qrCreate(method);
      if (_gen != myGen) return; // superseded while creating
      _qrImage = session.image;
      _pollKey = session.pollKey;
      _qrLoading = false;
      _qrStatus = QqcnQrStatus.waiting;
      notifyListeners();
      await _pollLoop(myGen, method, session.pollKey);
    } catch (e) {
      debugPrint('QqcnAuthProvider.startLogin failed: $e');
      if (_gen == myGen) {
        _qrLoading = false;
        _qrStatus = QqcnQrStatus.unknown;
        notifyListeners();
      }
    } finally {
      if (_gen == myGen) {
        _polling = false;
        _pollKey = null;
      }
    }
  }

  Future<void> _pollLoop(int gen, QqcnLoginMethod method, String key) async {
    final DateTime deadline = DateTime.now().add(_timeout);
    while (_gen == gen && _polling && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_interval);
      if (_gen != gen || !_polling) return;
      if (await _pollOnce(method, key)) return;
    }
    if (_gen == gen && _polling && _qrStatus != QqcnQrStatus.confirmed) {
      _qrStatus = QqcnQrStatus.expired;
      notifyListeners();
    }
  }

  /// One poll. Returns true when finished (confirmed / expired / canceled).
  Future<bool> _pollOnce(QqcnLoginMethod method, String key) async {
    if (_pollInFlight) return false;
    _pollInFlight = true;
    try {
      final QqcnQrPoll res = await api.qrPoll(method, key);
      _qrStatus = res.status;
      if (res.status == QqcnQrStatus.confirmed) {
        // The scan confirmed, but login isn't done until the OAuth handoff lands
        // the qm_keyst session — surface a "正在登录…" state while it runs.
        _finishing = true;
        notifyListeners();
        final bool ok = await api.completeLogin(method, res.payload ?? '');
        _isLoggedIn = ok;
        _finishing = false;
        if (ok) {
          await _refreshAccount();
          router.refresh();
        }
        notifyListeners();
        return true;
      }
      notifyListeners();
      return res.status == QqcnQrStatus.expired ||
          res.status == QqcnQrStatus.canceled;
    } catch (e) {
      debugPrint('QqcnAuthProvider.qrPoll error: $e');
      return false;
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> pollNow() async {
    final String? key = _pollKey;
    if (!_polling || key == null) return;
    if (await _pollOnce(_method, key)) _polling = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_polling) {
      unawaited(pollNow());
    } else if (_isLoggedIn && !_handlingExpiry) {
      // Re-validate the session on foreground so an expiry that happened while
      // backgrounded is caught before the user hits a silently-failing call.
      unawaited(api.verifyLoginState());
    }
  }

  void cancelLogin() {
    _polling = false;
    _qrLoading = false;
    _pollKey = null;
    notifyListeners();
  }

  /// Signs out the CURRENT account (removes the active one, switching to the next
  /// saved account; the last one drops to logged-out).
  Future<void> logout() async {
    final String? id = _activeId;
    if (id != null) {
      await removeAccount(id);
      return;
    }
    await api.logout();
    _isLoggedIn = false;
    _account = null;
    _qrStatus = QqcnQrStatus.unknown;
    _qrImage = null;
    notifyListeners();
    router.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _polling = false;
    super.dispose();
  }
}

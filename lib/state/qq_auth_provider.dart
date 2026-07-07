import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../models/cookie_account.dart';
import '../models/qq_login.dart';
import '../services/cookie_account_store.dart';
import '../services/music_api_router.dart';
import '../services/qq_api.dart';
import '../services/qq_cookie_store.dart';

/// QR-login state machine for QQ Music, supporting BOTH scan methods (微信 / QQ,
/// per QQMUSIC_API.md). Mirrors the Netease [AuthProvider]: create a session,
/// poll every 2s (300s timeout), and on confirmation finish the OAuth handoff
/// ([QqApi.completeLogin]) so the `qm_keyst` session cookie lands — then
/// `router.refresh()` reloads the (now non-empty) QQ feeds. Cookie-based single
/// account (the jar is the persistence), like Netease.
///
/// Background-resilient: the user leaves the app to scan, so an on-resume
/// [pollNow] catches a confirmation that arrived while backgrounded.
class QqAuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  final QqApi api;
  final QqCookieStore cookies;
  final MusicApiRouter router;

  QqAuthProvider({
    required this.api,
    required this.cookies,
    required this.router,
    CookieAccountStore? accountStore,
  }) : _store = accountStore ?? const CookieAccountStore('qq_accounts.json') {
    _isLoggedIn = cookies.isLoggedIn;
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
    if (_isLoggedIn) await _refreshAccount();
  }

  static const Duration _interval = Duration(seconds: 2);
  static const Duration _timeout = Duration(seconds: 300);

  bool _isLoggedIn = false;
  QqAccount? _account;
  QqLoginMethod _method = QqLoginMethod.qq;
  Uint8List? _qrImage;
  QqQrStatus _qrStatus = QqQrStatus.unknown;
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
  QqAccount? get account => _account;
  QqLoginMethod get method => _method;
  Uint8List? get qrImage => _qrImage;
  QqQrStatus get qrStatus => _qrStatus;
  bool get qrLoading => _qrLoading;

  /// Scan confirmed, OAuth handoff in flight — show "正在登录…", not "登录成功".
  bool get finishingLogin => _finishing;

  /// All saved QQ accounts (multi-account); tap one to [switchAccount].
  List<CookieAccount> get accounts => _accounts;
  String? get activeId => _activeId;

  Future<void> _refreshAccount() async {
    try {
      final QqAccount? acct = await api.accountProfile();
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
    final QqAccount? acct = _account;
    if (acct == null || acct.uin.isEmpty || acct.uin == '0') return;
    final Map<String, String> snap = await cookies.snapshot();
    if ((snap['qm_keyst'] ?? snap['qqmusic_key'] ?? '').isEmpty) return;
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
  Future<void> startLogin(QqLoginMethod method) async {
    final int myGen = ++_gen;
    _method = method;
    _polling = true;
    _qrLoading = true;
    _qrStatus = QqQrStatus.unknown;
    _qrImage = null;
    notifyListeners();
    try {
      final QqQrSession session = await api.qrCreate(method);
      if (_gen != myGen) return; // superseded while creating
      _qrImage = session.image;
      _pollKey = session.pollKey;
      _qrLoading = false;
      _qrStatus = QqQrStatus.waiting;
      notifyListeners();
      await _pollLoop(myGen, method, session.pollKey);
    } catch (e) {
      debugPrint('QqAuthProvider.startLogin failed: $e');
      if (_gen == myGen) {
        _qrLoading = false;
        _qrStatus = QqQrStatus.unknown;
        notifyListeners();
      }
    } finally {
      if (_gen == myGen) {
        _polling = false;
        _pollKey = null;
      }
    }
  }

  Future<void> _pollLoop(int gen, QqLoginMethod method, String key) async {
    final DateTime deadline = DateTime.now().add(_timeout);
    while (_gen == gen && _polling && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_interval);
      if (_gen != gen || !_polling) return;
      if (await _pollOnce(method, key)) return;
    }
    if (_gen == gen && _polling && _qrStatus != QqQrStatus.confirmed) {
      _qrStatus = QqQrStatus.expired;
      notifyListeners();
    }
  }

  /// One poll. Returns true when finished (confirmed / expired / canceled).
  Future<bool> _pollOnce(QqLoginMethod method, String key) async {
    if (_pollInFlight) return false;
    _pollInFlight = true;
    try {
      final QqQrPoll res = await api.qrPoll(method, key);
      _qrStatus = res.status;
      if (res.status == QqQrStatus.confirmed) {
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
      return res.status == QqQrStatus.expired ||
          res.status == QqQrStatus.canceled;
    } catch (e) {
      debugPrint('QqAuthProvider.qrPoll error: $e');
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
    if (state == AppLifecycleState.resumed && _polling) {
      unawaited(pollNow());
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
    _qrStatus = QqQrStatus.unknown;
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

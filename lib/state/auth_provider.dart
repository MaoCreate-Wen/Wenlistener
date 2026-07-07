import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/cookie_account.dart';
import '../models/qr_login.dart';
import '../services/cookie_account_store.dart';
import '../services/cookie_store.dart';
import '../services/music_api_router.dart';
import '../services/netease_api.dart';

/// QR-login state machine: creates a unikey, renders [qrContent], and polls
/// every 2s (300s timeout) until authorized / expired. On any auth-state change
/// it calls [MusicApiRouter.refresh] so the feeds reload against the new state —
/// the source itself is now a user setting (default Netease), not flipped here.
///
/// **Background-resilient.** The user must leave the app (to the NetEase Music
/// app) to scan, which on Android suspends the timed poll loop — so the 803
/// (authorized) reply that lands while we're backgrounded would otherwise be
/// missed. As a [WidgetsBindingObserver] we fire an immediate [pollNow] the
/// moment the app returns to the foreground, catching that 803 without waiting
/// for (or depending on) the frozen 2s ticker.
class AuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  final NeteaseApi api;
  final CookieStore cookies;
  final MusicApiRouter router;

  AuthProvider({
    required this.api,
    required this.cookies,
    required this.router,
    CookieAccountStore? accountStore,
  }) : _store = accountStore ??
            const CookieAccountStore('netease_accounts.json') {
    _isLoggedIn = cookies.isLoggedIn;
    WidgetsBinding.instance.addObserver(this);
    // Load the saved account set, then validate a *restored* session against the
    // server on startup. A MUSIC_U present in the jar may be stale (expired /
    // logged-out server-side), which otherwise strands the app "logged in" while
    // every authed call silently fails — 每日推荐 / 我的歌单 come back empty and
    // eapi 逐字歌词 falls back to plain LRC. refreshLoginState clears the dead
    // cookies and drops to logged-out when the profile cleanly reports so.
    unawaited(_init());
  }

  /// Persisted multi-account set (see [switchAccount]/[removeAccount]). The live
  /// cookie jar always holds the ACTIVE account's cookies; each saved account is
  /// a full snapshot of a past login so it can be restored on switch.
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
      await refreshLoginState();
    }
  }

  static const Duration _interval = Duration(seconds: 2);
  // Generous window: the user has to switch to NetEase Music, scan and confirm.
  static const Duration _timeout = Duration(seconds: 300);

  bool _isLoggedIn = false;
  NeteaseAccount? _account;
  QrStatus _qrStatus = QrStatus.unknown;
  String? _qrContent;
  bool _qrLoading = false;
  bool _polling = false;

  /// The unikey of the active QR session (so [pollNow] can re-poll it).
  String? _activeUniKey;

  /// Guards the timed loop and [pollNow] from issuing overlapping polls.
  bool _pollInFlight = false;

  bool get isLoggedIn => _isLoggedIn;

  /// The signed-in account (uid / nickname / avatar / vipType) once a profile
  /// has been fetched; null when logged out or before the profile resolves.
  NeteaseAccount? get account => _account;
  QrStatus get qrStatus => _qrStatus;
  String? get qrContent => _qrContent;
  bool get qrLoading => _qrLoading;

  /// All saved Netease accounts (multi-account). Tap one in the accounts page to
  /// [switchAccount]; the active one's cookies are what's live in the jar.
  List<CookieAccount> get accounts => _accounts;
  String? get activeId => _activeId;

  /// Reconciles login state with the cookie jar (the source of truth), then —
  /// only as enrichment — fetches the account profile.
  ///
  /// The presence of `MUSIC_U` in the jar is authoritative: a transient/network
  /// failure on the profile fetch must NOT downgrade a valid login. We only
  /// clear cookies when the server *cleanly* reports "not logged in"
  /// (`accountProfile()` returns null), which avoids the old bug where a single
  /// throw reverted a good session to logged-out.
  Future<void> refreshLoginState() async {
    await cookies.reload(); // jar -> cache (MUSIC_U / __csrf)
    _isLoggedIn = cookies.isLoggedIn; // authoritative: MUSIC_U present
    if (_isLoggedIn) {
      try {
        final NeteaseAccount? acct = await api.accountProfile(); // caches uid
        if (acct == null) {
          // Server cleanly reports not-logged-in (e.g. an expired restored
          // session) → drop the stale cookies and fall back to the anonymous
          // Migu default, so the UI reflects logged-out and prompts a re-scan
          // instead of silently failing every authed call.
          await cookies.clear();
          _account = null;
          _isLoggedIn = false;
        } else {
          _account = acct;
        }
      } catch (e) {
        // Transient/network error: keep the cookie-based truth, do NOT downgrade.
        debugPrint('AuthProvider.refreshLoginState: profile fetch failed, '
            'keeping cookie-based login state: $e');
      }
    }
    // Capture the (now-validated) active login as a saved account so it survives
    // an account switch — a snapshot of the jar keyed by uid.
    if (_isLoggedIn && _account != null) {
      await _captureActiveAccount();
    }
    // Reload the feeds against the new auth state. The source is now a user
    // setting (default Netease), so a login no longer flips it — refresh() fires
    // LibraryProvider._onSourceChanged (home + user playlists reload with the
    // now-cached uid) without changing the source.
    router.refresh();
    notifyListeners();
  }

  /// Snapshots the live jar + the fetched profile into the saved-account set
  /// (keyed by uid), making it the active account.
  Future<void> _captureActiveAccount() async {
    final NeteaseAccount? acct = _account;
    if (acct == null || acct.uid == 0) return;
    final Map<String, String> snap = await cookies.snapshot();
    if ((snap['MUSIC_U'] ?? '').isEmpty) return; // don't save a cookie-less blob
    final String id = acct.uid.toString();
    final CookieAccount ca = CookieAccount(
      id: id,
      nickname: acct.nickname,
      avatarUrl: acct.avatarUrl,
      vipType: acct.vipType,
      cookies: snap,
    );
    _accounts = <CookieAccount>[
      for (final CookieAccount a in _accounts)
        if (a.id != id) a,
      ca,
    ];
    _activeId = id;
    await _store.save(_accounts, _activeId);
  }

  /// Switches the active Netease account: restores its cookie snapshot into the
  /// live jar, then re-validates + reloads feeds. No-op if already active/unknown.
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
    await refreshLoginState();
  }

  /// Removes a saved account. If it was active, falls back to the first remaining
  /// account (restoring its cookies) or to logged-out when none are left.
  Future<void> removeAccount(String id) async {
    _accounts =
        _accounts.where((CookieAccount a) => a.id != id).toList();
    if (_activeId == id) {
      if (_accounts.isNotEmpty) {
        _activeId = _accounts.first.id;
        await _store.save(_accounts, _activeId);
        await cookies.restore(_accounts.first.cookies);
        await refreshLoginState();
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

  Future<void> startQrLogin() async {
    if (_polling) return;
    _polling = true;
    _qrLoading = true;
    _qrStatus = QrStatus.unknown;
    _qrContent = null;
    notifyListeners();
    try {
      final QrCreateResult created = await api.qrCreate();
      _qrContent = created.qrContent;
      _activeUniKey = created.uniKey;
      _qrLoading = false;
      notifyListeners();
      await _pollLoop(created.uniKey);
    } catch (e) {
      debugPrint('AuthProvider.startQrLogin failed: $e');
      _qrLoading = false;
      _qrStatus = QrStatus.unknown;
      notifyListeners();
    } finally {
      _polling = false;
      _activeUniKey = null;
    }
  }

  Future<void> _pollLoop(String uniKey) async {
    final DateTime deadline = DateTime.now().add(_timeout);
    while (_polling && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_interval);
      if (!_polling) return;
      final bool done = await _pollOnce(uniKey);
      if (done) return;
    }
    if (_polling && _qrStatus != QrStatus.authorized) {
      _qrStatus = QrStatus.expired;
      notifyListeners();
    }
  }

  /// A single poll of [uniKey]. Returns true once the session is finished
  /// (authorized / expired / invalidated) so callers stop. Shared by the timed
  /// loop and [pollNow]; the [_pollInFlight] guard ensures the two never issue
  /// overlapping requests (a resume firing mid-tick simply defers to the tick).
  Future<bool> _pollOnce(String uniKey) async {
    if (_pollInFlight) return false;
    _pollInFlight = true;
    try {
      final QrPollResult res = await api.qrPoll(uniKey);
      _qrStatus = res.status;
      notifyListeners();
      if (res.status == QrStatus.authorized) {
        await refreshLoginState();
        return true;
      }
      if (res.status == QrStatus.expired ||
          res.status == QrStatus.invalidated) {
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('AuthProvider.qrPoll error: $e');
      return false;
    } finally {
      _pollInFlight = false;
    }
  }

  /// Out-of-band poll fired on app-resume (see the class doc). No-op when not
  /// polling. On success it stops the loop (which sees `_polling == false` on
  /// its next tick).
  Future<void> pollNow() async {
    final String? key = _activeUniKey;
    if (!_polling || key == null) return;
    final bool done = await _pollOnce(key);
    if (done) _polling = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _polling) {
      unawaited(pollNow());
    }
  }

  void cancelQrLogin() {
    _polling = false;
    _qrLoading = false;
    _activeUniKey = null;
    notifyListeners();
  }

  /// Signs out the CURRENT account. With multiple saved accounts this removes the
  /// active one and switches to the next; the last one drops to logged-out.
  Future<void> logout() async {
    final String? id = _activeId;
    if (id != null) {
      await removeAccount(id);
      return;
    }
    await cookies.clear();
    _isLoggedIn = false;
    _account = null;
    _qrStatus = QrStatus.unknown;
    _qrContent = null;
    notifyListeners();
    // Reload feeds for the now-anonymous state (source stays the user setting).
    router.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _polling = false;
    super.dispose();
  }
}

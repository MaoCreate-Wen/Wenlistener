import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/kugou_account.dart';
import '../services/kugou_account_store.dart';
import '../services/kugou_api.dart';
import '../services/music_api_router.dart';

/// Owns the user's Kugou (酷狗) accounts — a small MULTI-ACCOUNT manager. Kugou's
/// full-song playback is gated behind a login (`err 30020`); this provider runs
/// the QR sign-in, keeps a persisted set of accounts, tracks which is active, and
/// pushes the active account's credential into [KugouApi] so play/search
/// authenticate. Switching accounts just re-applies + `router.refresh()`.
///
/// The QR half mirrors the Netease [AuthProvider]: create → poll every 2s (300s
/// timeout), and — because scanning means leaving the app — an on-resume
/// [pollNow] catches a confirmation that landed while backgrounded.
class KugouAuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  final KugouApi api;
  final KugouAccountStore store;
  final MusicApiRouter router;

  KugouAuthProvider({
    required this.api,
    required this.store,
    required this.router,
  }) {
    // Drop the active account when a play call reports the token expired; the
    // handler is guarded by activeUserId.
    api.onSessionExpired = _handleSessionExpired;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_init());
  }

  static const Duration _interval = Duration(seconds: 2);
  static const Duration _timeout = Duration(seconds: 300);

  List<KugouAccount> _accounts = <KugouAccount>[];
  String? _activeUserId;
  bool _loaded = false;

  KugouQrStatus _qrStatus = KugouQrStatus.unknown;
  String? _qrImage;
  bool _qrLoading = false;
  bool _polling = false;
  String? _activeQrcode;
  bool _pollInFlight = false;

  /// All signed-in Kugou accounts (newest kept as-is; switch order is by id).
  List<KugouAccount> get accounts => _accounts;
  bool get loaded => _loaded;

  /// The active account (its credential is installed in [KugouApi]) or null.
  KugouAccount? get active {
    final String? id = _activeUserId;
    if (id == null) return null;
    for (final KugouAccount a in _accounts) {
      if (a.userId == id) return a;
    }
    return null;
  }

  String? get activeUserId => _activeUserId;

  /// Whether a usable Kugou credential is active (unlocks full-song playback).
  bool get isLoggedIn => active?.isValid ?? false;

  KugouQrStatus get qrStatus => _qrStatus;

  /// The scannable QR as a `data:image/png;base64,…` url (render with Image.memory).
  String? get qrImage => _qrImage;
  bool get qrLoading => _qrLoading;

  Future<void> _init() async {
    final ({List<KugouAccount> accounts, String? activeUserId}) data =
        await store.load();
    _accounts = data.accounts;
    // Fall back to the first account if the persisted active id is stale.
    _activeUserId = data.activeUserId ??
        (_accounts.isNotEmpty ? _accounts.first.userId : null);
    _loaded = true;
    // Install the restored credential. Only refresh the feeds when there's
    // actually an account — with none, setAccount(null) is a no-op and a startup
    // router.refresh() would just cause a redundant home reload.
    api.setAccount(active);
    if (active != null) router.refresh();
    notifyListeners();
  }

  /// Installs the active account into both Kugou backends (web + 概念版) and reloads
  /// feeds so anything gated behind the login re-resolves.
  void _apply() {
    api.setAccount(active);
    router.refresh();
  }

  Future<void> _persist() => store.save(_accounts, _activeUserId);

  // --- QR login ------------------------------------------------------------

  Future<void> startQrLogin() async {
    if (_polling) return;
    _polling = true;
    _qrLoading = true;
    _qrStatus = KugouQrStatus.unknown;
    _qrImage = null;
    notifyListeners();
    try {
      final KugouQrCreate created = await api.qrCreate();
      _qrImage = created.imageDataUrl;
      _activeQrcode = created.qrcode;
      _qrLoading = false;
      _qrStatus = KugouQrStatus.waiting;
      notifyListeners();
      await _pollLoop(created.qrcode);
    } catch (e) {
      debugPrint('KugouAuthProvider.startQrLogin failed: $e');
      _qrLoading = false;
      _qrStatus = KugouQrStatus.unknown;
      notifyListeners();
    } finally {
      _polling = false;
      _activeQrcode = null;
    }
  }

  Future<void> _pollLoop(String qrcode) async {
    final DateTime deadline = DateTime.now().add(_timeout);
    while (_polling && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_interval);
      if (!_polling) return;
      final bool done = await _pollOnce(qrcode);
      if (done) return;
    }
    if (_polling && _qrStatus != KugouQrStatus.confirmed) {
      _qrStatus = KugouQrStatus.expired;
      notifyListeners();
    }
  }

  /// One poll. Returns true when the session is finished (confirmed / expired).
  Future<bool> _pollOnce(String qrcode) async {
    if (_pollInFlight) return false;
    _pollInFlight = true;
    try {
      final KugouQrPoll res = await api.qrPoll(qrcode);
      _qrStatus = res.status;
      if (res.status == KugouQrStatus.confirmed && res.account != null) {
        await _onConfirmed(res.account!);
        notifyListeners();
        return true;
      }
      notifyListeners();
      return res.status == KugouQrStatus.expired;
    } catch (e) {
      debugPrint('KugouAuthProvider.qrPoll error: $e');
      return false;
    } finally {
      _pollInFlight = false;
    }
  }

  /// Adds (or replaces, by userId) the newly-confirmed account, makes it active,
  /// persists and applies it.
  Future<void> _onConfirmed(KugouAccount account) async {
    final List<KugouAccount> next = <KugouAccount>[
      for (final KugouAccount a in _accounts)
        if (a.userId != account.userId) a,
      account,
    ];
    _accounts = next;
    _activeUserId = account.userId;
    _apply();
    await _persist();
  }

  /// Handles an expired-token signal from [KugouApi] (a logged-in play call came
  /// back `err 30020`). Removes the dead account and falls back to the next
  /// saved one (or logged-out). Kugou has no refresh token, so recovery is a
  /// fresh QR scan — with the account gone, `isLoggedIn` is false and the
  /// settings page auto-restarts the QR login. Guarded to the still-active
  /// account so a stale callback for an already-switched account is ignored.
  void _handleSessionExpired(String userId) {
    if (_activeUserId != userId) return;
    _accounts =
        _accounts.where((KugouAccount a) => a.userId != userId).toList();
    _activeUserId = _accounts.isNotEmpty ? _accounts.first.userId : null;
    _apply(); // reinstall the fallback credential (or null) + refresh feeds
    notifyListeners();
    unawaited(_persist());
  }

  /// Out-of-band poll fired on app-resume (the user scans in the Kugou app).
  Future<void> pollNow() async {
    final String? code = _activeQrcode;
    if (!_polling || code == null) return;
    final bool done = await _pollOnce(code);
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
    _activeQrcode = null;
    notifyListeners();
  }

  // --- account management --------------------------------------------------

  /// Switches the active account (no-op if unknown / already active).
  Future<void> switchTo(String userId) async {
    if (_activeUserId == userId) return;
    if (!_accounts.any((KugouAccount a) => a.userId == userId)) return;
    _activeUserId = userId;
    _apply();
    notifyListeners();
    await _persist();
  }

  /// Removes an account. If it was active, falls back to the first remaining
  /// account (or none), re-applying the credential.
  Future<void> removeAccount(String userId) async {
    final int before = _accounts.length;
    _accounts =
        _accounts.where((KugouAccount a) => a.userId != userId).toList();
    if (_accounts.length == before) return;
    if (_activeUserId == userId) {
      _activeUserId = _accounts.isNotEmpty ? _accounts.first.userId : null;
    }
    _apply();
    notifyListeners();
    await _persist();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _polling = false;
    super.dispose();
  }
}

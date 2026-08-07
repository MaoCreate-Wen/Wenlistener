import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/kugougn_account.dart';
import '../services/kugougn_account_store.dart';
import '../services/kugougn_api.dart';
import '../services/music_api_router.dart';

/// Owns the user's Kugougn (酷狗 概念版) accounts — a small MULTI-ACCOUNT manager.
/// Full-track playback is gated behind a login; this provider runs the phone
/// number + SMS verify-code sign-in ([sendMobileCode] → [loginWithVerifyCode]),
/// keeps a persisted set of accounts, tracks the active one, and installs its
/// credential into [KugougnApi] so play/search authenticate. Switching accounts
/// re-applies + `router.refresh()`.
///
/// (Replaces the former QR flow — the 概念版 backend has no scannable-QR endpoint,
/// it authenticates with a mobile verify code.)
class KugougnAuthProvider extends ChangeNotifier {
  final KugougnApi api;
  final KugougnAccountStore store;
  final MusicApiRouter router;

  KugougnAuthProvider({
    required this.api,
    required this.store,
    required this.router,
  }) {
    // Drop the active account when a request reports the token expired.
    api.onSessionExpired = _handleSessionExpired;
    unawaited(_init());
  }

  List<KugougnAccount> _accounts = <KugougnAccount>[];
  String? _activeUserId;
  bool _loaded = false;

  // --- phone-login transient state ---
  KugougnLoginStage _loginStage = KugougnLoginStage.idle;
  String? _loginError;
  String _loginPhone = '';
  DateTime? _codeSentAt;

  /// Mandatory wait before a verify code can be re-requested (concept app: 60s).
  static const Duration resendCooldown = Duration(seconds: 60);

  /// When the last SMS code was successfully requested (drives the resend
  /// countdown in the UI); null if none sent this session.
  DateTime? get codeSentAt => _codeSentAt;

  /// All signed-in Kugougn accounts.
  List<KugougnAccount> get accounts => _accounts;
  bool get loaded => _loaded;

  /// The active account (its credential is installed in [KugougnApi]) or null.
  KugougnAccount? get active {
    final String? id = _activeUserId;
    if (id == null) return null;
    for (final KugougnAccount a in _accounts) {
      if (a.userId == id) return a;
    }
    return null;
  }

  String? get activeUserId => _activeUserId;

  /// Whether a usable Kugougn credential is active (unlocks full-track playback).
  bool get isLoggedIn => active?.isValid ?? false;

  /// Current stage of the phone + SMS login flow.
  KugougnLoginStage get loginStage => _loginStage;

  /// Human-readable error from the last failed login step (null otherwise).
  String? get loginError => _loginError;

  /// The phone number the SMS code was requested for (for the code-entry UI).
  String get loginPhone => _loginPhone;

  /// True once a code has been sent and the user should be entering it.
  bool get awaitingCode => _loginStage == KugougnLoginStage.codeSent ||
      _loginStage == KugougnLoginStage.loggingIn;

  Future<void> _init() async {
    final ({List<KugougnAccount> accounts, String? activeUserId}) data =
        await store.load();
    _accounts = data.accounts;
    _activeUserId = data.activeUserId ??
        (_accounts.isNotEmpty ? _accounts.first.userId : null);
    _loaded = true;
    api.setAccount(active);
    if (active != null) router.refresh();
    notifyListeners();
  }

  void _apply() {
    api.setAccount(active);
    router.refresh();
  }

  Future<void> _persist() => store.save(_accounts, _activeUserId);

  // --- phone + SMS login ---------------------------------------------------

  /// Step 1: request an SMS verify code for [phone] (11-digit mainland mobile).
  /// On success [loginStage] becomes [KugougnLoginStage.codeSent].
  Future<void> sendMobileCode(String phone) async {
    _loginPhone = phone.trim();
    _loginStage = KugougnLoginStage.sendingCode;
    _loginError = null;
    notifyListeners();
    try {
      await api.sendMobileCode(_loginPhone);
      _codeSentAt = DateTime.now();
      _loginStage = KugougnLoginStage.codeSent;
    } catch (e) {
      debugPrint('KugougnAuthProvider.sendMobileCode failed: $e');
      _loginStage = KugougnLoginStage.error;
      _loginError = _messageOf(e);
    }
    notifyListeners();
  }

  /// Step 2: exchange [phone]+[code] for an account, make it active + persist.
  /// On success [loginStage] becomes [KugougnLoginStage.success].
  Future<void> loginWithVerifyCode(String phone, String code) async {
    _loginStage = KugougnLoginStage.loggingIn;
    _loginError = null;
    notifyListeners();
    try {
      final KugougnAccount account =
          await api.loginByVerifyCode(phone.trim(), code.trim());
      await _onConfirmed(account);
      _loginStage = KugougnLoginStage.success;
    } catch (e) {
      debugPrint('KugougnAuthProvider.loginWithVerifyCode failed: $e');
      _loginStage = KugougnLoginStage.error;
      _loginError = _messageOf(e);
    }
    notifyListeners();
  }

  /// Resets the login flow back to idle (e.g. when the panel is closed or the
  /// user wants to re-enter their number).
  void resetLogin() {
    _loginStage = KugougnLoginStage.idle;
    _loginError = null;
    _loginPhone = '';
    notifyListeners();
  }

  // --- daily sign-in (免费 VIP 签到) ---------------------------------------
  bool _signingIn = false;
  String? _signInMessage;

  /// True while a [signInDaily] request is in flight (drives the button spinner).
  bool get signingIn => _signingIn;

  /// The last sign-in result summary (claimed / already-signed / error), or null.
  String? get signInMessage => _signInMessage;

  /// Runs the 概念版 daily free-VIP sign-in for the ACTIVE account and stashes a
  /// user-facing summary in [signInMessage]. No-op (with a hint) when logged out.
  Future<void> signInDaily() async {
    if (_signingIn) return;
    if (!isLoggedIn) {
      _signInMessage = '请先登录酷狗账号';
      notifyListeners();
      return;
    }
    _signingIn = true;
    _signInMessage = null;
    notifyListeners();
    try {
      final KugougnSignInResult r = await api.signInDaily();
      _signInMessage = r.message;
      // A fresh VIP claim can change gating — refresh feeds so it reflects.
      if (r.anyClaimed) router.refresh();
    } catch (e) {
      debugPrint('KugougnAuthProvider.signInDaily failed: $e');
      _signInMessage = _messageOf(e);
    }
    _signingIn = false;
    notifyListeners();
  }

  /// Adds (or replaces, by userId) the newly-confirmed account, makes it active,
  /// persists and applies it.
  Future<void> _onConfirmed(KugougnAccount account) async {
    final List<KugougnAccount> next = <KugougnAccount>[
      for (final KugougnAccount a in _accounts)
        if (a.userId != account.userId) a,
      account,
    ];
    _accounts = next;
    _activeUserId = account.userId;
    _apply();
    await _persist();
  }

  /// Handles an expired-token signal from [KugougnApi]. Removes the dead account
  /// and falls back to the next saved one (or logged-out). Guarded to the still-
  /// active account so a stale callback for an already-switched account is
  /// ignored.
  void _handleSessionExpired(String userId) {
    if (_activeUserId != userId) return;
    _accounts =
        _accounts.where((KugougnAccount a) => a.userId != userId).toList();
    _activeUserId = _accounts.isNotEmpty ? _accounts.first.userId : null;
    _apply();
    notifyListeners();
    unawaited(_persist());
  }

  // --- account management --------------------------------------------------

  /// Switches the active account (no-op if unknown / already active).
  Future<void> switchTo(String userId) async {
    if (_activeUserId == userId) return;
    if (!_accounts.any((KugougnAccount a) => a.userId == userId)) return;
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
        _accounts.where((KugougnAccount a) => a.userId != userId).toList();
    if (_accounts.length == before) return;
    if (_activeUserId == userId) {
      _activeUserId = _accounts.isNotEmpty ? _accounts.first.userId : null;
    }
    _apply();
    notifyListeners();
    await _persist();
  }

  /// Signs out the active account (falls back to the next saved one, if any).
  Future<void> logout() async {
    final String? id = _activeUserId;
    if (id != null) await removeAccount(id);
  }

  String _messageOf(Object e) {
    if (e is KugougnApiException) return e.message;
    return e.toString();
  }
}

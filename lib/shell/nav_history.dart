import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

/// Browser-style navigation history for the desktop top bar's ◀ ▶ arrows.
///
/// go_router has no forward stack and `canPop` does not span branch
/// (`goBranch`) switches, so we keep our **own** two-stack history driven by the
/// router's location. `router.go(location)` (not pop/push) makes ◀ ▶ uniform
/// across branch switches, pushed sheets (`/player`, `/lyrics`) and detail
/// routes. Dialogs use the raw `Navigator`, so they never enter this history.
class NavHistory extends ChangeNotifier {
  NavHistory(this._router) {
    _current = _loc();
    _router.routeInformationProvider.addListener(_onLocationChanged);
  }

  final GoRouter _router;
  final List<String> _back = <String>[];
  final List<String> _forward = <String>[];
  String _current = '/';

  /// Set while WE drive `go()` so the resulting location change is not recorded
  /// as a genuine forward navigation.
  bool _navigating = false;

  bool get canBack => _back.isNotEmpty;
  bool get canForward => _forward.isNotEmpty;

  String _loc() => _router.routeInformationProvider.value.uri.toString();

  void _onLocationChanged() {
    final String next = _loc();
    if (next == _current) return;
    if (_navigating) {
      _navigating = false;
      _current = next;
      notifyListeners();
      return;
    }
    // Genuine forward navigation — clear the redo stack.
    _back.add(_current);
    _forward.clear();
    _current = next;
    notifyListeners();
  }

  void back() {
    if (_back.isEmpty) return;
    _forward.add(_current);
    final String prev = _back.removeLast();
    _navigating = true;
    _router.go(prev);
  }

  void forward() {
    if (_forward.isEmpty) return;
    _back.add(_current);
    final String next = _forward.removeLast();
    _navigating = true;
    _router.go(next);
  }

  @override
  void dispose() {
    _router.routeInformationProvider.removeListener(_onLocationChanged);
    super.dispose();
  }
}

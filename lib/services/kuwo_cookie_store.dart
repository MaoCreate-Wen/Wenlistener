import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Stores login credentials for Kuwo (酷我音乐): the numeric `userid`, the
/// session `websid`, and the analytics cookie `Hm_Iuvt_*` (required on every
/// request). When not logged in only the Hm cookie is seeded so searches still
/// work; play URLs via `anti.s` require a valid `userid`+`websid`.
class KuwoCookieStore {
  static const String _fileName = 'kuwo_cookies.json';
  static const String _hmCookieName =
      'Hm_Iuvt_cdb524f42f23cer9b268564v7y735ewrq2324';
  // A stable public value for the Hm cookie — the API only needs its presence.
  static const String _hmDefault = 'cdb524f42f23cer9b268564v7y735ewrq2324xx';

  String _userid = '';
  String _websid = '';
  String _hmCookie = _hmDefault;
  bool _loaded = false;

  bool get isLoggedIn => _userid.isNotEmpty && _websid.isNotEmpty;
  String get userid => _userid;
  String get websid => _websid;

  /// Cookie header value for requests to `www.kuwo.cn` / `m.kuwo.cn`.
  String get cookieHeader {
    final StringBuffer sb = StringBuffer('$_hmCookieName=$_hmCookie');
    if (isLoggedIn) {
      sb..write('; userid=$_userid')..write('; websid=$_websid');
    }
    return sb.toString();
  }

  Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final File f = await _file();
      if (!await f.exists()) return;
      final String raw = await f.readAsString();
      if (raw.trim().isEmpty) return;
      final dynamic d = jsonDecode(raw);
      if (d is! Map) return;
      _userid = (d['userid'] ?? '').toString();
      _websid = (d['websid'] ?? '').toString();
      _hmCookie = (d['hmCookie'] ?? _hmDefault).toString();
    } catch (e) {
      debugPrint('KuwoCookieStore.load failed: $e');
    }
  }

  Future<void> saveLoginCookies(Map<String, String> cookies) async {
    _userid = cookies['userid'] ?? cookies['Userid'] ?? _userid;
    _websid = cookies['websid'] ?? cookies['SID'] ?? _websid;
    final String? hm = cookies[_hmCookieName];
    if (hm != null && hm.isNotEmpty) _hmCookie = hm;
    await _persist();
  }

  Future<void> clear() async {
    _userid = '';
    _websid = '';
    _hmCookie = _hmDefault;
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final File f = await _file();
      final File tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, dynamic>{
          'userid': _userid,
          'websid': _websid,
          'hmCookie': _hmCookie,
        }),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('KuwoCookieStore._persist failed: $e');
    }
  }
}

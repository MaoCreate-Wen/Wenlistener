import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/cookie_account.dart';

/// Persisted set of saved cookie-based accounts (网易云 / QQ音乐) + which is active.
/// One instance per source (distinct [fileName]). Same atomic `.tmp`+rename write
/// + swallow-all-errors strategy as the other stores, so a corrupt file never
/// blocks startup — it just falls back to an empty set.
class CookieAccountStore {
  final String fileName;
  const CookieAccountStore(this.fileName);

  static const int _version = 1;

  Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }

  Future<({List<CookieAccount> accounts, String? activeId})> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return (accounts: <CookieAccount>[], activeId: null);
      }
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return (accounts: <CookieAccount>[], activeId: null);
      }
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map || (decoded['version'] as num?)?.toInt() != _version) {
        return (accounts: <CookieAccount>[], activeId: null);
      }
      final List<CookieAccount> out = <CookieAccount>[];
      final dynamic list = decoded['accounts'];
      if (list is List) {
        for (final dynamic e in list) {
          if (e is Map) {
            out.add(CookieAccount.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
      final String? active = decoded['activeId']?.toString();
      return (
        accounts: out,
        activeId: (active != null && active.isNotEmpty) ? active : null,
      );
    } catch (e) {
      debugPrint('CookieAccountStore($fileName).load failed: $e');
      return (accounts: <CookieAccount>[], activeId: null);
    }
  }

  Future<void> save(List<CookieAccount> accounts, String? activeId) async {
    try {
      final File file = await _file();
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, dynamic>{
          'version': _version,
          'activeId': activeId,
          'accounts': accounts.map((CookieAccount a) => a.toJson()).toList(),
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('CookieAccountStore($fileName).save failed: $e');
    }
  }
}

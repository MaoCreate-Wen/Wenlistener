import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/kugougn_account.dart';

/// Persisted set of signed-in Kugougn (酷狗) accounts + which one is active — the
/// storage behind the multi-account manager. Written to `kugougn_accounts.json`
/// under the app-support dir (same atomic `.tmp`+rename strategy as the other
/// stores). Every IO/parse error is swallowed → falls back to an empty set, so a
/// corrupt file never blocks startup.
class KugougnAccountStore {
  static const String _fileName = 'kugougn_accounts.json';
  static const int _version = 1;

  Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<({List<KugougnAccount> accounts, String? activeUserId})> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return (accounts: <KugougnAccount>[], activeUserId: null);
      }
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return (accounts: <KugougnAccount>[], activeUserId: null);
      }
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return (accounts: <KugougnAccount>[], activeUserId: null);
      }
      final Map<String, dynamic> m = Map<String, dynamic>.from(decoded);
      if ((m['version'] as num?)?.toInt() != _version) {
        return (accounts: <KugougnAccount>[], activeUserId: null);
      }
      final List<KugougnAccount> out = <KugougnAccount>[];
      final dynamic list = m['accounts'];
      if (list is List) {
        for (final dynamic e in list) {
          if (e is Map) {
            out.add(KugougnAccount.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
      final String? active = m['activeUserId']?.toString();
      return (
        accounts: out,
        activeUserId: (active != null && active.isNotEmpty) ? active : null,
      );
    } catch (e) {
      debugPrint('KugougnAccountStore.load failed: $e');
      return (accounts: <KugougnAccount>[], activeUserId: null);
    }
  }

  Future<void> save(List<KugougnAccount> accounts, String? activeUserId) async {
    try {
      final File file = await _file();
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, dynamic>{
          'version': _version,
          'activeUserId': activeUserId,
          'accounts': accounts.map((KugougnAccount a) => a.toJson()).toList(),
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('KugougnAccountStore.save failed: $e');
    }
  }
}

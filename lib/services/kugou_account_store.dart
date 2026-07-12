import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/kugou_account.dart';

/// Persisted set of signed-in Kugou (酷狗) accounts + which one is active — the
/// storage behind the multi-account manager. Written to `kugou_accounts.json`
/// under the app-support dir (same atomic `.tmp`+rename strategy as the other
/// stores). Every IO/parse error is swallowed → falls back to an empty set, so a
/// corrupt file never blocks startup.
class KugouAccountStore {
  static const String _fileName = 'kugou_accounts.json';
  static const int _version = 1;

  Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<({List<KugouAccount> accounts, String? activeUserId})> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return (accounts: <KugouAccount>[], activeUserId: null);
      }
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return (accounts: <KugouAccount>[], activeUserId: null);
      }
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return (accounts: <KugouAccount>[], activeUserId: null);
      }
      final Map<String, dynamic> m = Map<String, dynamic>.from(decoded);
      if ((m['version'] as num?)?.toInt() != _version) {
        return (accounts: <KugouAccount>[], activeUserId: null);
      }
      final List<KugouAccount> out = <KugouAccount>[];
      final dynamic list = m['accounts'];
      if (list is List) {
        for (final dynamic e in list) {
          if (e is Map) {
            out.add(KugouAccount.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
      final String? active = m['activeUserId']?.toString();
      return (
        accounts: out,
        activeUserId: (active != null && active.isNotEmpty) ? active : null,
      );
    } catch (e) {
      debugPrint('KugouAccountStore.load failed: $e');
      return (accounts: <KugouAccount>[], activeUserId: null);
    }
  }

  Future<void> save(List<KugouAccount> accounts, String? activeUserId) async {
    try {
      final File file = await _file();
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, dynamic>{
          'version': _version,
          'activeUserId': activeUserId,
          'accounts': accounts.map((KugouAccount a) => a.toJson()).toList(),
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('KugouAccountStore.save failed: $e');
    }
  }
}

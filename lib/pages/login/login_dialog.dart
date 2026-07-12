import 'package:flutter/widgets.dart';

import '../../models/song.dart';
import '../../widgets/dialog_shell.dart';
import '../playlist/desktop_kit.dart';
import 'login_page.dart';

/// Opens per-source login (QR / password) as a dismissible glass dialog —
/// replacing the old dead-end `/login/:source` route. Hosts the reused
/// [LoginPanel]; on success the panel pops the dialog automatically.
Future<void> showLoginDialog(BuildContext context, MusicSource source) {
  return showWenDialog<void>(
    context,
    title: '登录 · ${dkSourceLabel(source)}',
    width: 480,
    child: LoginPanel(source: dkSourceLoginToken(source)),
  );
}

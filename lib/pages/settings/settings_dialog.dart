import 'package:flutter/widgets.dart';

import '../../widgets/dialog_shell.dart';
import 'settings_page.dart';

/// Opens 设置 as a dismissible glass dialog — replacing the old settings shell
/// branch. Hosts the reused [SettingsBody].
Future<void> showSettingsDialog(BuildContext context) {
  return showWenDialog<void>(
    context,
    title: '设置',
    width: 720,
    child: const SettingsBody(),
  );
}

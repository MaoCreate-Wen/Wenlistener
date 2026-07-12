import 'package:flutter/widgets.dart';

import '../../widgets/dialog_shell.dart';
import 'accounts_page.dart';

/// Opens the multi-account manager (账号管理) as a dismissible glass dialog —
/// replacing the old dead-end `/accounts` route. Hosts the reused [AccountsBody].
Future<void> showAccountsDialog(BuildContext context) {
  return showWenDialog<void>(
    context,
    title: '账号管理',
    width: 720,
    child: const AccountsBody(),
  );
}

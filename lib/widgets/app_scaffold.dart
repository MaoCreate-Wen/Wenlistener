import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

/// Black scaffold with an optional art-driven gradient wash behind the content.
/// When [showDynamicWash] is true it reads [PlayerProvider.washGradient], which
/// is decided **once** (first track of the session) and then frozen — so the
/// feed keeps a stable tint instead of re-colouring on every song change.
/// Otherwise the scaffold stays fully decoupled.
class AppScaffold extends StatelessWidget {
  final Widget body;
  final PreferredSizeWidget? appBar;
  final bool showDynamicWash;
  final EdgeInsetsGeometry? padding;

  const AppScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.showDynamicWash = false,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final Widget content = Padding(
      padding: padding ??
          const EdgeInsets.symmetric(horizontal: AppDimens.screenPadding),
      child: body,
    );
    return Scaffold(
      backgroundColor: AppColors.bg,
      extendBodyBehindAppBar: true,
      appBar: appBar,
      body: showDynamicWash ? _wash(context, content) : content,
    );
  }

  Widget _wash(BuildContext context, Widget content) {
    // washGradient changes at most once (first palette of the session), so this
    // select rebuilds the wash a single time and then never again.
    final Gradient gradient =
        context.select<PlayerProvider, Gradient>((PlayerProvider p) => p.washGradient);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: DecoratedBox(decoration: BoxDecoration(gradient: gradient)),
        ),
        Positioned.fill(
          child: ColoredBox(color: AppColors.bg.withValues(alpha: 0.55)),
        ),
        content,
      ],
    );
  }
}

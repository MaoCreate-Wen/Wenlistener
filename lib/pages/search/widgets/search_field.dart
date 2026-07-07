import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_typography.dart';
import '../../../widgets/glass_container.dart';

/// Frosted-glass pill search input with a leading magnifier and a 44px clear
/// button. Owns its [TextEditingController] so the host page can stay stateless
/// and react through [onSubmitted] / [onChanged] / [onClear].
class SearchField extends StatefulWidget {
  final String? initialText;
  final String? hintText;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const SearchField({
    super.key,
    this.initialText,
    this.hintText,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    this.onClear,
  });

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);
  late final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleClear() {
    _controller.clear();
    widget.onClear?.call();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      radius: AppDimens.radiusPill,
      opacity: 0.08,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space4,
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.search_rounded,
            size: 22,
            color: AppColors.onSurfaceMuted,
          ),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: widget.autofocus,
              textInputAction: TextInputAction.search,
              cursorColor: Theme.of(context).colorScheme.primary,
              style: AppTypography.body,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.hintText ?? 'Search',
                hintStyle: AppTypography.body.copyWith(
                  color: AppColors.onSurfaceFaint,
                ),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder:
                (BuildContext context, TextEditingValue value, Widget? child) {
              if (value.text.isEmpty) {
                return const SizedBox(width: AppDimens.space4);
              }
              return _ClearButton(onTap: _handleClear);
            },
          ),
        ],
      ),
    );
  }
}

class _ClearButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ClearButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: const SizedBox(
        width: AppDimens.minTouch,
        height: AppDimens.minTouch,
        child: Center(
          child: Icon(
            Icons.close_rounded,
            size: 20,
            color: AppColors.onSurfaceMuted,
          ),
        ),
      ),
    );
  }
}

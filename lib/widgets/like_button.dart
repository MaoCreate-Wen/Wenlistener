import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Heart toggle; fills with the theme accent when liked.
class LikeButton extends StatelessWidget {
  final bool liked;
  final VoidCallback onPressed;
  final double size;

  const LikeButton({
    super.key,
    required this.liked,
    required this.onPressed,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return IconButton(
      onPressed: onPressed,
      iconSize: size,
      tooltip: liked ? 'Unlike' : 'Like',
      icon: Icon(
        liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: liked ? accent : AppColors.onSurfaceMuted,
      ),
    );
  }
}

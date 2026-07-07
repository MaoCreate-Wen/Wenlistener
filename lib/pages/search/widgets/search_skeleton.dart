import 'package:flutter/material.dart';

import '../../../theme/app_dimens.dart';
import '../../../widgets/skeleton_box.dart';

/// Placeholder list that mirrors the [SongTile] row metrics (56px artwork + two
/// text lines) so swapping in real results causes no layout jump.
class SearchSkeleton extends StatelessWidget {
  final int itemCount;
  const SearchSkeleton({super.key, this.itemCount = 10});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: AppDimens.space24),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) => const _SkeletonRow(),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(
        vertical: AppDimens.space8,
        horizontal: AppDimens.space8,
      ),
      child: Row(
        children: <Widget>[
          SkeletonBox(
            width: AppDimens.tileArtwork,
            height: AppDimens.tileArtwork,
            radius: AppDimens.radiusMd,
          ),
          SizedBox(width: AppDimens.space12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: 0.65,
                  child: SkeletonBox(height: 14, radius: 7),
                ),
                SizedBox(height: AppDimens.space8),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: 0.4,
                  child: SkeletonBox(height: 12, radius: 6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

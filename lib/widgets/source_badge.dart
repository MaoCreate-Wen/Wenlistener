import 'package:flutter/material.dart';

import '../models/song.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

/// Human label for a music [source]. The `migu` enum slot currently hosts QQ音乐
/// (see the wiring docs), hence the mapping.
String sourceLabel(MusicSource source) {
  switch (source) {
    case MusicSource.netease:
      return '网易云';
    case MusicSource.migu:
      return 'QQ音乐';
    case MusicSource.kugou:
      return '酷狗';
    case MusicSource.kugougn:
      return '概念版';
    case MusicSource.kuwo:
      return '酷我';
    case MusicSource.qqcn:
      return 'QQ音乐(安卓)';
    case MusicSource.local:
      return '本地';
  }
}

/// Small per-song source chip shown in dense track rows / cards so a mixed
/// (cross-source 共同歌单) list reads at a glance.
class SourceBadge extends StatelessWidget {
  final MusicSource source;
  const SourceBadge({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Text(
        sourceLabel(source),
        style: const TextStyle(
          fontSize: 10,
          height: 1.2,
          color: AppColors.onSurfaceMuted,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

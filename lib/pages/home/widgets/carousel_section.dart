import 'package:flutter/material.dart';

import '../../../models/home_section.dart';
import '../../../theme/app_dimens.dart';
import '../../../widgets/section_header.dart';
import 'playlist_card.dart';

/// A horizontally-scrolling row of [PlaylistCard]s under a [SectionHeader].
/// Used for the playlist / album carousels on the discovery feed.
class CarouselSection extends StatelessWidget {
  const CarouselSection({super.key, required this.section, this.onMore});

  final HomeSection section;
  final VoidCallback? onMore;

  /// Width of each card; the carousel height is derived from it.
  static const double cardWidth = 150;
  static const double _height = cardWidth + AppDimens.space8 + 48;

  @override
  Widget build(BuildContext context) {
    final List<dynamic> playlists = section.playlists;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: AppDimens.screenPadding),
          child: SectionHeader(title: section.title, onMore: onMore),
        ),
        SizedBox(
          height: _height,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.screenPadding,
            ),
            itemCount: section.playlists.length,
            cacheExtent: 600,
            itemBuilder: (BuildContext context, int index) {
              return Padding(
                padding: EdgeInsets.only(
                  right: index == playlists.length - 1 ? 0 : AppDimens.space12,
                ),
                child: PlaylistCard(
                  playlist: section.playlists[index],
                  width: cardWidth,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

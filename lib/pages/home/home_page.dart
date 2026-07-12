import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/home_section.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../router/routes.dart';
import '../../state/library_provider.dart';
import '../../state/player_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import 'widgets/desktop_widgets.dart';

/// Desktop **Home / discovery** feed.
///
/// A single [CustomScrollView]: a display-font greeting hero, then the
/// [LibraryProvider.homeSections] rendered as desktop surfaces — horizontal
/// hover-scroll carousels for 每日推荐 / 推荐歌单 and a responsive reflowing grid
/// for 推荐歌曲. Cards hover-scale (paint-only) and reveal a play affordance;
/// playlist cards open `/playlist/:id`, song cards start a queue. Loads the feed
/// once on mount and shows skeleton carousels while it resolves. Consumes the
/// providers via `context.select` (never rewrites logic).
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final LibraryProvider lib = context.read<LibraryProvider>();
      if (!lib.homeLoading && lib.homeSections.isEmpty && !lib.homeError) {
        lib.loadHome();
      }
    });
  }

  String get _greeting {
    final int h = DateTime.now().hour;
    if (h < 6) return '夜深了';
    if (h < 12) return '早上好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  @override
  Widget build(BuildContext context) {
    final bool loading =
        context.select((LibraryProvider p) => p.homeLoading);
    final bool error = context.select((LibraryProvider p) => p.homeError);
    final List<HomeSection> sections =
        context.select((LibraryProvider p) => p.homeSections);
    final MusicSource source =
        context.select((LibraryProvider p) => p.source);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(child: _hero(source)),
        if (error && sections.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              title: '无法加载推荐',
              message: '检查网络后重试，或切换其他音源。',
              actionLabel: '重试',
              onAction: () => context.read<LibraryProvider>().loadHome(),
            ),
          )
        else if (loading && sections.isEmpty)
          _skeletonSlivers()
        else if (sections.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.explore_rounded,
              title: '暂无推荐',
              message: '当前音源没有可展示的发现内容。',
            ),
          )
        else
          ..._sectionSlivers(sections),
        const SliverToBoxAdapter(child: SizedBox(height: AppDimens.space48)),
      ],
    );
  }

  // --- hero greeting ---------------------------------------------------------

  Widget _hero(MusicSource source) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.screenPadding,
        AppDimens.space32,
        AppDimens.screenPadding,
        AppDimens.space24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(_greeting, style: AppTypography.displayL),
          const SizedBox(height: AppDimens.space8),
          Row(
            children: <Widget>[
              Text(
                '当前音源 · ${sourceLabel(source)}',
                style: AppTypography.label.copyWith(
                  color: AppColors.accentOf(context),
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text('   今天想听点什么？', style: AppTypography.label),
            ],
          ),
        ],
      ),
    );
  }

  // --- real sections ---------------------------------------------------------

  List<Widget> _sectionSlivers(List<HomeSection> sections) {
    final List<Widget> out = <Widget>[];
    for (final HomeSection s in sections) {
      switch (s.kind) {
        case HomeSectionKind.dailySongs:
          out.add(_songCarousel(s));
          break;
        case HomeSectionKind.playlistCarousel:
        case HomeSectionKind.albumCarousel:
          out.add(_playlistCarousel(s));
          break;
        case HomeSectionKind.recommendedGrid:
          out.add(_songGrid(s));
          break;
      }
    }
    return out;
  }

  Widget _sectionPadding({required Widget child}) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.screenPadding,
          AppDimens.space8,
          AppDimens.screenPadding,
          AppDimens.sectionGap,
        ),
        sliver: SliverToBoxAdapter(child: child),
      );

  Widget _songCarousel(HomeSection s) {
    return _sectionPadding(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionHeader(title: s.title, subtitle: s.subtitle),
          CarouselRow(
            // cover(150) + 8 + body-line(21.75) + 2 + caption-line(15.4) ≈ 197px;
            // reserve a couple px extra so the card never overflows on DPI rounding.
            height: AppDimens.cardSize + 50,
            children: <Widget>[
              for (int i = 0; i < s.songs.length; i++)
                MediaCard(
                  artUrl: s.songs[i].artworkUrl,
                  title: s.songs[i].name,
                  subtitle: s.songs[i].artistNames,
                  onTap: () => _playFrom(s.songs, i),
                  onPlay: () => _playFrom(s.songs, i),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _playlistCarousel(HomeSection s) {
    return _sectionPadding(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionHeader(title: s.title, subtitle: s.subtitle),
          CarouselRow(
            height: AppDimens.cardSize + 50,
            children: <Widget>[
              for (final Playlist p in s.playlists)
                MediaCard(
                  artUrl: p.coverUrl,
                  title: p.name,
                  subtitle: p.creatorName ?? p.description,
                  onTap: () => context.push(Routes.playlistPath(p.id)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _songGrid(HomeSection s) {
    return _sectionPadding(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionHeader(title: s.title, subtitle: s.subtitle),
          Wrap(
            spacing: AppDimens.space16,
            runSpacing: AppDimens.space20,
            children: <Widget>[
              for (int i = 0; i < s.songs.length; i++)
                MediaCard(
                  artUrl: s.songs[i].artworkUrl,
                  title: s.songs[i].name,
                  subtitle: s.songs[i].artistNames,
                  onTap: () => _playFrom(s.songs, i),
                  onPlay: () => _playFrom(s.songs, i),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // --- skeletons -------------------------------------------------------------

  Widget _skeletonSlivers() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.screenPadding),
      sliver: SliverList(
        delegate: SliverChildListDelegate(<Widget>[
          for (int band = 0; band < 2; band++) ...<Widget>[
            const SizedBox(height: AppDimens.space8),
            const SkeletonBox(width: 160, height: 22),
            const SizedBox(height: AppDimens.space16),
            SizedBox(
              height: AppDimens.cardSize + 50,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 6,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: AppDimens.space16),
                itemBuilder: (_, __) => const SkeletonCard(),
              ),
            ),
            const SizedBox(height: AppDimens.sectionGap),
          ],
        ]),
      ),
    );
  }

  // --- actions ---------------------------------------------------------------

  void _playFrom(List<Song> songs, int index) =>
      context.read<PlayerProvider>().playQueue(songs, index: index);
}

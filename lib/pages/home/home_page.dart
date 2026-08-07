import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/home_section.dart';
import '../../models/song.dart';
import '../../router/routes.dart';
import '../../state/library_provider.dart';
import '../../state/qqcn_auth_provider.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/skeleton_box.dart';
import 'widgets/carousel_section.dart';
import 'widgets/greeting_header.dart';
import 'widgets/recommended_grid.dart';

/// Home / discovery feed: a greeting header followed by the
/// [LibraryProvider.homeSections] (playlist carousels + a recommended grid).
/// Loading, empty and error states all degrade gracefully so the page renders
/// without depending on live data.
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
      if (!mounted) return;
      final LibraryProvider library = context.read<LibraryProvider>();
      if (library.homeSections.isEmpty && !library.homeLoading) {
        library.loadHome();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final LibraryProvider library = context.watch<LibraryProvider>();
    final MusicSource source =
        context.select<SettingsProvider, MusicSource>((s) => s.source);
    // QQ 音乐（安卓 `qqcn` 源）needs a login before recommendations mean anything —
    // read (not watch): a QQ login fires a LibraryProvider reload via the router,
    // which already rebuilds this page. (source != qqcn skips the read, so the
    // widget test — which has no QqcnAuthProvider — is unaffected.)
    final bool qqNeedsLogin = source == MusicSource.qqcn &&
        !context.read<QqcnAuthProvider>().isLoggedIn;
    return AppScaffold(
      showDynamicWash: true,
      padding: EdgeInsets.zero,
      body: CustomScrollView(
        cacheExtent: 600,
        slivers: _slivers(context, library, qqNeedsLogin),
      ),
    );
  }

  List<Widget> _slivers(
    BuildContext context,
    LibraryProvider library,
    bool qqNeedsLogin,
  ) {
    final double topInset = MediaQuery.of(context).padding.top;
    final List<HomeSection> sections = library.homeSections
        .where((HomeSection s) => s.playlists.isNotEmpty || s.songs.isNotEmpty)
        .toList();

    final List<Widget> slivers = <Widget>[
      SliverToBoxAdapter(
        child: SizedBox(height: topInset + AppDimens.space12),
      ),
      const SliverToBoxAdapter(child: GreetingHeader()),
    ];

    if (qqNeedsLogin) {
      // On the QQ source without a login: prompt to sign in instead of an empty
      // feed (QQ returns nothing until logged in).
      slivers.add(_qqLoginSliver(context));
    } else if (sections.isEmpty && library.homeLoading) {
      slivers.add(const SliverToBoxAdapter(child: _HomeSkeleton()));
    } else if (sections.isEmpty && library.homeError) {
      slivers.add(
        _messageSliver(
          context,
          icon: Icons.cloud_off_rounded,
          title: '加载失败',
          subtitle: '请检查网络后重试',
          actionLabel: '重试',
        ),
      );
    } else if (sections.isEmpty) {
      slivers.add(
        _messageSliver(
          context,
          icon: Icons.library_music_outlined,
          title: '暂时没有推荐内容',
          subtitle: '稍后再来看看',
          actionLabel: '刷新',
        ),
      );
    } else {
      for (final HomeSection section in sections) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppDimens.space8),
              child: _sectionWidget(section),
            ),
          ),
        );
      }
    }

    slivers.add(
      const SliverToBoxAdapter(child: SizedBox(height: AppDimens.space32)),
    );
    return slivers;
  }

  Widget _sectionWidget(HomeSection section) {
    switch (section.kind) {
      // The daily-songs feed reuses the recommended grid; it renders its own
      // title + optional subtitle (and per-song reason) from [section].
      case HomeSectionKind.dailySongs:
      case HomeSectionKind.recommendedGrid:
        return RecommendedGrid(section: section);
      case HomeSectionKind.playlistCarousel:
      case HomeSectionKind.albumCarousel:
        return CarouselSection(section: section);
    }
  }

  /// QQ-source login prompt (shown instead of an empty recommendation feed when
  /// the QQ source isn't signed in). Tapping opens the QQ scan-login page.
  Widget _qqLoginSliver(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.screenPadding,
          AppDimens.space48,
          AppDimens.screenPadding,
          AppDimens.space24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.qr_code_2_rounded,
                color: AppColors.onSurfaceFaint, size: 48),
            const SizedBox(height: AppDimens.space16),
            Text('登录 QQ 音乐', style: AppTypography.titleM),
            const SizedBox(height: AppDimens.space8),
            Text(
              'QQ 音乐源需登录后才能搜索与查看个性化推荐',
              style: AppTypography.label,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppDimens.space16),
            TextButton(
              onPressed: () => context.push(Routes.qqLogin),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onSurface,
                backgroundColor: AppColors.surfaceGlass,
                minimumSize:
                    const Size(AppDimens.minTouch * 2, AppDimens.minTouch),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
              ),
              child: const Text('扫码登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageSliver(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String actionLabel,
  }) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.screenPadding,
          AppDimens.space48,
          AppDimens.screenPadding,
          AppDimens.space24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: AppColors.onSurfaceFaint, size: 48),
            const SizedBox(height: AppDimens.space16),
            Text(title, style: AppTypography.titleM, textAlign: TextAlign.center),
            const SizedBox(height: AppDimens.space8),
            Text(
              subtitle,
              style: AppTypography.label,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppDimens.space16),
            TextButton(
              onPressed: () => context.read<LibraryProvider>().loadHome(),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onSurface,
                backgroundColor: AppColors.surfaceGlass,
                minimumSize:
                    const Size(AppDimens.minTouch * 2, AppDimens.minTouch),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
              ),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// Placeholder layout shown while the first home load is in flight: a skeleton
/// carousel row and grid that reserve the same space the real content will fill.
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.screenPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: AppDimens.space8),
          const SkeletonBox(width: 120, height: 22, radius: AppDimens.radiusSm),
          const SizedBox(height: AppDimens.space12),
          SizedBox(
            height: CarouselSection.cardWidth + AppDimens.space8 + 36,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 4,
              itemBuilder: (BuildContext context, int index) => const Padding(
                padding: EdgeInsets.only(right: AppDimens.space12),
                child: _CardSkeleton(width: CarouselSection.cardWidth),
              ),
            ),
          ),
          const SizedBox(height: AppDimens.space24),
          const SkeletonBox(width: 140, height: 22, radius: AppDimens.radiusSm),
          const SizedBox(height: AppDimens.space12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const <Widget>[
              Expanded(child: _CardSkeleton()),
              SizedBox(width: AppDimens.space12),
              Expanded(child: _CardSkeleton()),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton({this.width});

  /// Fixed art size; when null the artwork fills its (bounded) parent width.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final Widget art = width != null
        ? SkeletonBox(width: width, height: width, radius: AppDimens.radiusMd)
        : const AspectRatio(
            aspectRatio: 1,
            child: SkeletonBox(radius: AppDimens.radiusMd),
          );
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          art,
          const SizedBox(height: AppDimens.space8),
          const SkeletonBox(width: 100, height: 14, radius: AppDimens.radiusSm),
          const SizedBox(height: AppDimens.space4),
          const SkeletonBox(width: 64, height: 12, radius: AppDimens.radiusSm),
        ],
      ),
    );
  }
}

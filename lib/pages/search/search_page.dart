import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/search_result.dart';
import '../../models/song.dart';
import '../../router/routes.dart';
import '../../state/local_playlist_provider.dart';
import '../../state/player_provider.dart';
import '../../state/search_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/entrance.dart';
import '../home/widgets/desktop_widgets.dart';

/// Desktop **Search** page.
///
/// A pinned glass search pill + type chips (单曲 / 专辑 / 歌手 / 歌单) over a body
/// that switches on the active [SearchType]: songs render as a compact
/// multi-column [TrackRow] table (hover-to-reveal play, right-click → 共同歌单),
/// the other types render as a reflowing grid of [MediaCard]s. Infinite scroll
/// drives [SearchProvider.loadMore]; the empty query shows recent-history chips.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  static const List<SearchType> _types = <SearchType>[
    SearchType.song,
    SearchType.album,
    SearchType.artist,
    SearchType.playlist,
  ];

  @override
  void initState() {
    super.initState();
    _controller.text = context.read<SearchProvider>().query;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _typeLabel(SearchType t) {
    switch (t) {
      case SearchType.song:
        return '单曲';
      case SearchType.album:
        return '专辑';
      case SearchType.artist:
        return '歌手';
      case SearchType.playlist:
        return '歌单';
      case SearchType.lyric:
        return '歌词';
      case SearchType.comprehensive:
        return '综合';
    }
  }

  void _submit([String? q]) {
    final String kw = (q ?? _controller.text).trim();
    if (kw.isEmpty) return;
    _focus.unfocus();
    context.read<SearchProvider>().search(kw);
  }

  bool _onScroll(ScrollNotification n) {
    final SearchProvider sp = context.read<SearchProvider>();
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400 &&
        sp.hasMore &&
        !sp.isLoadingMore &&
        !sp.isLoading) {
      sp.loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _header(),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: _body(),
          ),
        ),
      ],
    );
  }

  // --- header: search pill + type chips -------------------------------------

  Widget _header() {
    final String query = context.select((SearchProvider p) => p.query);
    final SearchType active =
        context.select((SearchProvider p) => p.activeType);
    // Keep the field text in sync when the provider resets (source switch).
    // Deferred to after the frame — mutating the controller mid-build would
    // notify the TextField that is still being built.
    if (query.isEmpty && _controller.text.isNotEmpty && !_focus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            context.read<SearchProvider>().query.isEmpty &&
            !_focus.hasFocus) {
          _controller.clear();
        }
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.screenPadding,
        AppDimens.space24,
        AppDimens.screenPadding,
        AppDimens.space16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Container(
              height: 46,
              padding:
                  const EdgeInsets.symmetric(horizontal: AppDimens.space16),
              decoration: BoxDecoration(
                color: AppColors.glass,
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                border: Border.all(color: AppColors.glassBorder, width: 1),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.search_rounded,
                      size: 20, color: AppColors.onSurfaceMuted),
                  const SizedBox(width: AppDimens.space12),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      onChanged: (String v) =>
                          context.read<SearchProvider>().setQuery(v),
                      onSubmitted: _submit,
                      style: AppTypography.body,
                      cursorColor: AppColors.accentOf(context),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: '搜索歌曲、专辑、歌手、歌单',
                        hintStyle: AppTypography.body
                            .copyWith(color: AppColors.onSurfaceFaint),
                      ),
                    ),
                  ),
                  if (query.isNotEmpty)
                    _HeaderIcon(
                      icon: Icons.close_rounded,
                      tooltip: '清除',
                      onTap: () {
                        _controller.clear();
                        context.read<SearchProvider>().reset();
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppDimens.space16),
          DownwardReveal(
            wrap: true,
            spacing: AppDimens.space8,
            children: <Widget>[
              for (final SearchType t in _types)
                PillChip(
                  label: _typeLabel(t),
                  selected: active == t,
                  onTap: () => context.read<SearchProvider>().setType(t),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // --- body ------------------------------------------------------------------

  Widget _body() {
    final String query = context.select((SearchProvider p) => p.query);
    final bool isLoading = context.select((SearchProvider p) => p.isLoading);
    final bool hasError = context.select((SearchProvider p) => p.hasError);
    final SearchResult result =
        context.select((SearchProvider p) => p.result);

    if (query.trim().isEmpty) return _emptyQueryView();

    if (isLoading && _isResultEmpty(result)) return _skeletonBody(result.type);

    if (hasError && _isResultEmpty(result)) {
      return EmptyState(
        icon: Icons.error_outline_rounded,
        title: '搜索失败',
        message: '网络异常或该音源暂不支持，换个关键词或音源试试。',
        actionLabel: '重试',
        onAction: _submit,
      );
    }

    if (_isResultEmpty(result)) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: '没有找到结果',
        message: '试试其他关键词或切换搜索类型。',
      );
    }

    switch (result.type) {
      case SearchType.song:
        return _songTable(result.songs);
      case SearchType.playlist:
        return _playlistGrid(result.playlists);
      case SearchType.album:
        return _albumGrid(result.albums);
      case SearchType.artist:
        return _artistGrid(result.artists);
      case SearchType.lyric:
      case SearchType.comprehensive:
        return _songTable(result.songs);
    }
  }

  bool _isResultEmpty(SearchResult r) =>
      r.songs.isEmpty &&
      r.albums.isEmpty &&
      r.artists.isEmpty &&
      r.playlists.isEmpty;

  // --- empty query (history) -------------------------------------------------

  Widget _emptyQueryView() {
    final List<String> history =
        context.select((SearchProvider p) => p.history);
    if (history.isEmpty) {
      return EmptyState(
        icon: Icons.search_rounded,
        title: '搜索你的音乐',
        message: '输入歌曲、专辑、歌手或歌单名称开始。',
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.screenPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('搜索历史', style: AppTypography.titleM),
              const Spacer(),
              _HeaderIcon(
                icon: Icons.delete_outline_rounded,
                tooltip: '清空历史',
                onTap: () => context.read<SearchProvider>().clearHistory(),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space16),
          DownwardReveal(
            wrap: true,
            spacing: AppDimens.space8,
            runSpacing: AppDimens.space8,
            children: <Widget>[
              for (final String h in history)
                PillChip(
                  label: h,
                  selected: false,
                  icon: Icons.history_rounded,
                  onTap: () {
                    _controller.text = h;
                    _submit(h);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  // --- song table ------------------------------------------------------------

  Widget _songTable(List<Song> songs) {
    final bool loadingMore =
        context.select((SearchProvider p) => p.isLoadingMore);
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool showAlbum =
            constraints.maxWidth >= AppDimens.tableAlbumHideWidth;
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.screenPadding),
              child: TrackTableHeader(showAlbum: showAlbum),
            ),
            const Divider(height: 1, color: AppColors.glassBorder),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.screenPadding,
                  AppDimens.space8,
                  AppDimens.screenPadding,
                  AppDimens.space32,
                ),
                itemCount: songs.length + (loadingMore ? 1 : 0),
                itemBuilder: (context, int i) {
                  if (i >= songs.length) {
                    return const Padding(
                      padding: EdgeInsets.all(AppDimens.space16),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  final Song song = songs[i];
                  return TrackRow(
                    song: song,
                    displayIndex: i + 1,
                    showAlbum: showAlbum,
                    onPlay: () => context
                        .read<PlayerProvider>()
                        .playQueue(songs, index: i),
                    onContext: (Offset pos) =>
                        _songContextMenu(song, songs, i, pos),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // --- grids -----------------------------------------------------------------

  Widget _gridScaffold(List<Widget> cards) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.screenPadding,
        AppDimens.space8,
        AppDimens.screenPadding,
        AppDimens.space48,
      ),
      // 结果网格「向下展开」逐个落位（统一入场，见 widgets/entrance.dart）。
      child: DownwardReveal(
        wrap: true,
        spacing: AppDimens.space16,
        runSpacing: AppDimens.space20,
        children: cards,
      ),
    );
  }

  Widget _playlistGrid(List<Playlist> playlists) => _gridScaffold(<Widget>[
        for (final Playlist p in playlists)
          MediaCard(
            artUrl: p.coverUrl,
            title: p.name,
            subtitle: p.creatorName,
            onTap: () => context.push(Routes.playlistPath(p.id)),
          ),
      ]);

  Widget _albumGrid(List<Album> albums) => _gridScaffold(<Widget>[
        for (final Album a in albums)
          MediaCard(
            artUrl: a.picUrl,
            title: a.name,
            subtitle: '专辑',
            onTap: () {},
          ),
      ]);

  Widget _artistGrid(List<Artist> artists) => _gridScaffold(<Widget>[
        for (final Artist a in artists)
          MediaCard(
            artUrl: a.picUrl,
            title: a.name,
            subtitle: '歌手',
            circle: true,
            onTap: () {},
          ),
      ]);

  // --- skeletons -------------------------------------------------------------

  Widget _skeletonBody(SearchType type) {
    if (type == SearchType.song) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.screenPadding),
        children: const <Widget>[
          SizedBox(height: AppDimens.space8),
          TrackTableHeader(),
          Divider(height: 1, color: AppColors.glassBorder),
          SizedBox(height: AppDimens.space8),
          SkeletonRow(),
          SkeletonRow(),
          SkeletonRow(),
          SkeletonRow(),
          SkeletonRow(),
          SkeletonRow(),
          SkeletonRow(),
        ],
      );
    }
    return _gridScaffold(<Widget>[
      for (int i = 0; i < 10; i++) const SkeletonCard(),
    ]);
  }

  // --- context menu ----------------------------------------------------------

  Future<void> _songContextMenu(
    Song song,
    List<Song> queue,
    int index,
    Offset pos,
  ) async {
    final PlayerProvider player = context.read<PlayerProvider>();
    final LocalPlaylistProvider local = context.read<LocalPlaylistProvider>();
    final List<PopupMenuEntry<String>> items = <PopupMenuEntry<String>>[
      const PopupMenuItem<String>(value: 'play', child: Text('播放')),
      const PopupMenuDivider(),
      if (local.playlists.isEmpty)
        const PopupMenuItem<String>(
          value: 'new',
          child: Text('新建共同歌单并添加'),
        )
      else
        for (final p in local.playlists)
          PopupMenuItem<String>(
            value: 'add:${p.id}',
            child: Text('添加到 ${p.name}'),
          ),
    ];
    final String? picked = await showTrackMenu<String>(context, pos, items);
    if (picked == null) return;
    if (picked == 'play') {
      player.playQueue(queue, index: index);
    } else if (picked == 'new') {
      await local.create('我的收藏', tracks: <Song>[song]);
    } else if (picked.startsWith('add:')) {
      await local.addSong(picked.substring(4), song);
    }
  }
}

// ---------------------------------------------------------------------------

class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _HeaderIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovering) => Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Icon(
            icon,
            size: 18,
            color: hovering ? Colors.white : AppColors.onSurfaceMuted,
          ),
        ),
      ),
    );
  }
}

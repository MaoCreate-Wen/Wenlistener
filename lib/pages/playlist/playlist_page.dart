import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/local_playlist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../state/library_provider.dart';
import '../../state/local_playlist_provider.dart';
import '../../state/player_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/skeleton_box.dart';
import '../../widgets/song_tile.dart';
import 'widgets/playlist_header.dart';

/// Playlist detail: a collapsing [SliverAppBar] header over a virtualized list
/// of [SongTile] rows (numbered, with the active track highlighted). Loads the
/// playlist through [LibraryProvider] and degrades gracefully to skeleton /
/// empty / error states so it never depends on live data.
class PlaylistPage extends StatefulWidget {
  final int playlistId;

  const PlaylistPage({required this.playlistId, super.key});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  bool _error = false;

  /// Optimistic collect state for the SliverAppBar action; null until the user
  /// taps (the icon then reads [Playlist.subscribed] until overridden here).
  bool? _collected;

  /// The last successfully-loaded detail. Retained locally so an external cache
  /// drop (e.g. [LibraryProvider.collectPlaylist] invalidating the cached
  /// detail) doesn't blank the page back to a skeleton.
  Playlist? _retained;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final LibraryProvider library = context.read<LibraryProvider>();
    if (library.playlist(widget.playlistId) != null) {
      _markLikedIfLikedPlaylist(library);
      return;
    }
    if (_error) setState(() => _error = false);
    try {
      await library.loadPlaylist(widget.playlistId);
      if (mounted) _markLikedIfLikedPlaylist(library);
    } catch (e) {
      debugPrint('PlaylistPage load failed: $e');
      if (mounted) setState(() => _error = true);
    }
  }

  /// If this IS the user's liked playlist ("我喜欢的音乐" — [LibraryProvider]'s
  /// first user playlist), seed its track ids into [PlayerProvider]'s liked set so
  /// the ♥ lights immediately when a track from it is opened. This is independent
  /// of the one-shot login-time seeder (`_LikedSeeder`), which can race the async
  /// fetch or be skipped entirely on a restored session that starts on Netease
  /// (no source-change to trigger it) — the actual cause of the "heart not active
  /// for a liked-playlist song" bug.
  void _markLikedIfLikedPlaylist(LibraryProvider library) {
    final List<Playlist> ups = library.userPlaylists;
    if (ups.isEmpty || ups.first.id != widget.playlistId) return;
    final Playlist? pl = library.playlist(widget.playlistId);
    if (pl == null) return;
    context.read<PlayerProvider>().markLiked(pl.tracks.map((Song s) => s.id));
  }

  void _playAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    context.read<PlayerProvider>().playQueue(tracks, index: 0);
  }

  void _playFrom(List<Song> tracks, int index) {
    context.read<PlayerProvider>().playQueue(tracks, index: index);
  }

  /// "导入到本地歌单": forks this (Netease/Migu) playlist's CURRENT tracks into a new
  /// local cross-source list, so the user can then add 酷狗/其它音源 songs to it —
  /// pure local logic, no server write. Records the [LocalPlaylistOrigin] (source +
  /// remote id) so the local copy can later be RE-SYNCED against upstream while
  /// keeping the user's arrangement and any hand-added cross-source tracks in place.
  Future<void> _importToLocal(Playlist playlist) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (playlist.tracks.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('歌单还没有可导入的歌曲')),
      );
      return;
    }
    final MusicSource source = context.read<LibraryProvider>().source;
    final LocalPlaylist local =
        await context.read<LocalPlaylistProvider>().create(
              playlist.name,
              tracks: playlist.tracks,
              origin: LocalPlaylistOrigin(
                source: source,
                remoteId: playlist.id,
                remoteName: playlist.name,
              ),
            );
    messenger.showSnackBar(SnackBar(
      content: Text('已导入到本地歌单「${local.name}」，可再加入其它音源歌曲并随时同步'),
    ));
  }

  /// Optimistically flips the collect state, then calls through to the provider;
  /// reverts + SnackBars on error. The provider drops the cached detail on
  /// success, but [_retained] keeps the page populated.
  Future<void> _toggleCollect(Playlist playlist) async {
    final bool current = _collected ?? playlist.subscribed;
    final bool next = !current;
    setState(() => _collected = next);
    final LibraryProvider library = context.read<LibraryProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await library.collectPlaylist(playlist.id, next);
      messenger.showSnackBar(
        SnackBar(content: Text(next ? '已收藏' : '已取消收藏')),
      );
    } catch (e) {
      debugPrint('collectPlaylist failed: $e');
      if (mounted) setState(() => _collected = current);
      messenger.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final LibraryProvider library = context.watch<LibraryProvider>();
    final Playlist? cached = library.playlist(widget.playlistId);
    // Retain the last loaded detail so a cache drop (collect invalidation)
    // doesn't fall back to the skeleton; the optimistic [_collected] still
    // reflects the toggle.
    if (cached != null) _retained = cached;
    final Playlist? playlist = cached ?? _retained;
    final bool loading = library.isPlaylistLoading(widget.playlistId);

    // NOTE: build() deliberately reads NOTHING from PlayerProvider — switching
    // tracks must not rebuild this whole page (and re-run the SliverList builder
    // for every visible row, the切歌卡顿 regression). The active-row highlight and
    // the accent are selected inside the isolated child widgets below instead.
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        cacheExtent: 600,
        slivers: <Widget>[
          _PlaylistAppBar(
            playlist: playlist,
            collected: _collected,
            onToggleCollect: _toggleCollect,
            onPlayAll:
                playlist == null ? null : () => _playAll(playlist.tracks),
            onImport:
                playlist == null ? null : () => _importToLocal(playlist),
            onBack: () {
              if (context.canPop()) context.pop();
            },
          ),
          ..._body(context, playlist: playlist, loading: loading),
        ],
      ),
    );
  }

  List<Widget> _body(
    BuildContext context, {
    required Playlist? playlist,
    required bool loading,
  }) {
    if (playlist == null && _error) {
      return <Widget>[_errorSliver(context)];
    }
    if (playlist == null) {
      return <Widget>[const _TrackListSkeleton()];
    }
    if (playlist.tracks.isEmpty) {
      return <Widget>[_emptySliver(loading)];
    }
    final List<Song> tracks = playlist.tracks;
    return <Widget>[
      SliverList.builder(
        itemCount: tracks.length,
        itemBuilder: (BuildContext context, int index) => _PlaylistTrackRow(
          song: tracks[index],
          index: index,
          onTap: () => _playFrom(tracks, index),
        ),
      ),
      const SliverToBoxAdapter(
        child: SizedBox(height: AppDimens.space32),
      ),
    ];
  }

  Widget _errorSliver(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: _MessageState(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load this playlist",
        subtitle: 'Check your connection and try again',
        actionLabel: 'Retry',
        onAction: _load,
      ),
    );
  }

  Widget _emptySliver(bool loading) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: _MessageState(
        icon: Icons.queue_music_rounded,
        title: loading ? 'Loading…' : 'No tracks here yet',
        subtitle: loading ? '' : 'This playlist is empty',
      ),
    );
  }

}

/// Formats a track duration as `m:ss`.
String _fmtDuration(Duration d) {
  final int minutes = d.inMinutes;
  final int seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// The collapsing header. Selects the dynamic accent internally so a palette
/// change repaints only this app bar, not the whole track list.
class _PlaylistAppBar extends StatelessWidget {
  final Playlist? playlist;
  final bool? collected;
  final Future<void> Function(Playlist) onToggleCollect;
  final VoidCallback? onPlayAll;
  final VoidCallback? onImport;
  final VoidCallback onBack;

  const _PlaylistAppBar({
    required this.playlist,
    required this.collected,
    required this.onToggleCollect,
    required this.onPlayAll,
    required this.onImport,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = context.select<PlayerProvider, Color>(
      (PlayerProvider p) => p.dynamicAccent,
    );
    final Playlist? pl = playlist;
    final bool isCollected = collected ?? (pl?.subscribed ?? false);
    return SliverAppBar(
      pinned: true,
      expandedHeight: 360,
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        tooltip: 'Back',
        icon: const Icon(
          Icons.arrow_back_ios_new_rounded,
          color: AppColors.onSurface,
          size: 20,
        ),
        onPressed: onBack,
      ),
      actions: <Widget>[
        if (pl != null && onImport != null)
          IconButton(
            tooltip: '导入到本地歌单',
            icon: const Icon(Icons.library_add_rounded,
                color: AppColors.onSurface),
            onPressed: onImport,
          ),
        if (pl != null)
          IconButton(
            tooltip: isCollected ? '取消收藏' : '收藏',
            icon: Icon(
              isCollected
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: isCollected ? accent : AppColors.onSurface,
            ),
            onPressed: () => onToggleCollect(pl),
          ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.parallax,
        background: pl != null
            ? PlaylistHeader(
                coverUrl: pl.coverUrl,
                title: pl.name,
                creatorName: pl.creatorName,
                trackCount: pl.trackCount,
                playCount: pl.playCount,
                accent: accent,
                onPlayAll: onPlayAll ?? () {},
              )
            : const _HeaderSkeleton(),
      ),
    );
  }
}

/// One track row that selects ONLY its own active-state (and, when active, the
/// accent) — so switching tracks rebuilds just the two rows whose highlight
/// flips, never the whole visible list (the切歌卡顿 regression). A non-active row
/// never subscribes to the accent, so a palette change repaints only the active
/// row + the app bar.
class _PlaylistTrackRow extends StatelessWidget {
  final Song song;
  final int index;
  final VoidCallback onTap;

  const _PlaylistTrackRow({
    required this.song,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool isActive = context.select<PlayerProvider, bool>(
      (PlayerProvider p) => p.currentSong?.id == song.id,
    );
    final Color accent = isActive
        ? context.select<PlayerProvider, Color>(
            (PlayerProvider p) => p.dynamicAccent,
          )
        : AppColors.onSurfaceFaint;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space8),
      child: SongTile.fromSong(
        song,
        isActive: isActive,
        leading: _TrackLeading(index: index, isActive: isActive, accent: accent),
        trailing:
            Text(_fmtDuration(song.duration), style: AppTypography.caption),
        onTap: onTap,
      ),
    );
  }
}

/// The numeric leading slot: track number, swapped for an accent equalizer glyph
/// on the currently-playing row.
class _TrackLeading extends StatelessWidget {
  final int index;
  final bool isActive;
  final Color accent;

  const _TrackLeading({
    required this.index,
    required this.isActive,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppDimens.tileArtwork,
      height: AppDimens.tileArtwork,
      child: Center(
        child: isActive
            ? Icon(Icons.equalizer_rounded, color: accent, size: 22)
            : Text(
                '${index + 1}',
                style: AppTypography.label.copyWith(
                  color: AppColors.onSurfaceFaint,
                ),
              ),
      ),
    );
  }
}

/// Skeleton shown in the header area while the playlist loads.
class _HeaderSkeleton extends StatelessWidget {
  const _HeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return ColoredBox(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.screenPadding,
          0,
          AppDimens.screenPadding,
          AppDimens.space20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            SizedBox(height: topInset + AppDimens.space48),
            const SkeletonBox(width: 132, height: 132, radius: AppDimens.radiusMd),
            const SizedBox(height: AppDimens.space16),
            const SkeletonBox(width: 180, height: 22, radius: AppDimens.radiusSm),
            const SizedBox(height: AppDimens.space8),
            const SkeletonBox(width: 120, height: 14, radius: AppDimens.radiusSm),
          ],
        ),
      ),
    );
  }
}

/// Skeleton list of track rows used before the first load resolves.
class _TrackListSkeleton extends StatelessWidget {
  const _TrackListSkeleton();

  @override
  Widget build(BuildContext context) {
    return SliverList.builder(
      itemCount: 8,
      itemBuilder: (BuildContext context, int index) => const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppDimens.space16,
          vertical: AppDimens.space8,
        ),
        child: Row(
          children: <Widget>[
            SkeletonBox(
              width: AppDimens.tileArtwork,
              height: AppDimens.tileArtwork,
              radius: AppDimens.radiusSm,
            ),
            SizedBox(width: AppDimens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SkeletonBox(width: 160, height: 14, radius: AppDimens.radiusSm),
                  SizedBox(height: AppDimens.space8),
                  SkeletonBox(width: 100, height: 12, radius: AppDimens.radiusSm),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Centered icon + title + optional subtitle + optional action, reused for the
/// empty and error states.
class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppDimens.space32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, color: AppColors.onSurfaceFaint, size: 48),
          const SizedBox(height: AppDimens.space16),
          Text(title, style: AppTypography.titleM, textAlign: TextAlign.center),
          if (subtitle.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppDimens.space8),
            Text(subtitle, style: AppTypography.label, textAlign: TextAlign.center),
          ],
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: AppDimens.space16),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onSurface,
                backgroundColor: AppColors.surfaceGlass,
                minimumSize:
                    const Size(AppDimens.minTouch * 2, AppDimens.minTouch),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

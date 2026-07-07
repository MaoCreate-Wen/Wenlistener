import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/search_result.dart';
import '../../models/song.dart';
import '../../router/routes.dart';
import '../../state/player_provider.dart';
import '../../state/search_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/song_tile.dart';
import 'widgets/search_field.dart';
import 'widgets/search_skeleton.dart';
import 'widgets/search_tab_chips.dart';

/// Paginated search results. Reads [SearchProvider]; tab chips switch the active
/// [SearchType] (which re-queries), song taps start playback through
/// [PlayerProvider.playQueue], and album/playlist rows push the playlist route.
class SearchResultsPage extends StatelessWidget {
  const SearchResultsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final SearchProvider provider = context.watch<SearchProvider>();
    return AppScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            const SizedBox(height: AppDimens.space8),
            _ResultsHeader(query: provider.query),
            const SizedBox(height: AppDimens.space16),
            SearchTabChips(
              selected: provider.activeType,
              onSelected: (SearchType type) =>
                  context.read<SearchProvider>().setType(type),
            ),
            const SizedBox(height: AppDimens.space12),
            Expanded(child: _ResultsBody(provider: provider)),
          ],
        ),
      ),
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  final String query;
  const _ResultsHeader({required this.query});

  void _refine(BuildContext context, String raw) {
    final String value = raw.trim();
    if (value.isEmpty) return;
    final SearchProvider provider = context.read<SearchProvider>();
    provider.setQuery(value);
    provider.search(value);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _IconTapTarget(
          icon: Icons.arrow_back_ios_new_rounded,
          onTap: () {
            if (context.canPop()) context.pop();
          },
        ),
        const SizedBox(width: AppDimens.space8),
        Expanded(
          child: SearchField(
            initialText: query,
            hintText: 'Search',
            onSubmitted: (String value) => _refine(context, value),
          ),
        ),
      ],
    );
  }
}

class _ResultsBody extends StatelessWidget {
  final SearchProvider provider;
  const _ResultsBody({required this.provider});

  /// Whether the list for the *active* type is empty. Keyed off [activeType]
  /// (not all four lists) so switching tabs shows the skeleton during the
  /// re-query instead of the previous type's stale rows.
  bool get _activeEmpty {
    final SearchResult r = provider.result;
    switch (provider.activeType) {
      case SearchType.album:
        return r.albums.isEmpty;
      case SearchType.artist:
        return r.artists.isEmpty;
      case SearchType.playlist:
        return r.playlists.isEmpty;
      case SearchType.song:
      case SearchType.lyric:
      case SearchType.comprehensive:
        return r.songs.isEmpty;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (provider.isLoading && _activeEmpty) {
      return const SearchSkeleton();
    }
    if (provider.hasError && _activeEmpty) {
      return const _MessageState(
        icon: Icons.cloud_off_rounded,
        message: 'Something went wrong.\nTry searching again.',
      );
    }
    if (_activeEmpty) {
      return _MessageState(
        icon: Icons.search_off_rounded,
        message: provider.query.trim().isEmpty
            ? 'Type to search'
            : 'No results for "${provider.query}"',
      );
    }
    return _ResultsList(provider: provider);
  }
}

class _ResultsList extends StatelessWidget {
  final SearchProvider provider;
  const _ResultsList({required this.provider});

  int _countFor(SearchType type, SearchResult r) {
    switch (type) {
      case SearchType.album:
        return r.albums.length;
      case SearchType.artist:
        return r.artists.length;
      case SearchType.playlist:
        return r.playlists.length;
      case SearchType.song:
      case SearchType.lyric:
      case SearchType.comprehensive:
        return r.songs.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    final SearchResult result = provider.result;
    final SearchType type = provider.activeType;
    final int? currentId = context.select<PlayerProvider, int?>(
      (PlayerProvider p) => p.currentSong?.id,
    );
    final int baseCount = _countFor(type, result);
    final bool showLoader = provider.isLoadingMore;
    final int itemCount = baseCount + (showLoader ? 1 : 0);

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 360 &&
            provider.hasMore &&
            !provider.isLoadingMore &&
            !provider.isLoading) {
          context.read<SearchProvider>().loadMore();
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: AppDimens.space32),
        cacheExtent: 600,
        itemCount: itemCount,
        itemBuilder: (BuildContext context, int index) {
          if (index >= baseCount) {
            return const _LoadMoreFooter();
          }
          return _buildRow(context, type, result, index, currentId);
        },
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    SearchType type,
    SearchResult result,
    int index,
    int? currentId,
  ) {
    switch (type) {
      case SearchType.album:
        final Album album = result.albums[index];
        return SongTile(
          title: album.name,
          artist: 'Album',
          artworkUrl: album.picUrl,
          onTap: () => context.push(Routes.playlistPath(album.id)),
        );
      case SearchType.artist:
        final Artist artist = result.artists[index];
        return SongTile(
          title: artist.name,
          artist: 'Artist',
          artworkUrl: artist.picUrl,
        );
      case SearchType.playlist:
        final Playlist playlist = result.playlists[index];
        return SongTile(
          title: playlist.name,
          artist: playlist.creatorName ?? 'Playlist',
          artworkUrl: playlist.coverUrl,
          onTap: () => context.push(Routes.playlistPath(playlist.id)),
        );
      case SearchType.song:
      case SearchType.lyric:
      case SearchType.comprehensive:
        final Song song = result.songs[index];
        return SongTile.fromSong(
          song,
          isActive: song.id == currentId,
          onTap: () => context
              .read<PlayerProvider>()
              .playQueue(result.songs, index: index),
        );
    }
  }
}

class _IconTapTarget extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconTapTarget({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: AppDimens.minTouch,
        height: AppDimens.minTouch,
        child: Center(
          child: Icon(icon, size: 20, color: AppColors.onSurface),
        ),
      ),
    );
  }
}

class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppDimens.space16),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String message;
  const _MessageState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 48, color: AppColors.onSurfaceFaint),
          const SizedBox(height: AppDimens.space16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTypography.label,
          ),
        ],
      ),
    );
  }
}

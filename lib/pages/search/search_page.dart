import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../router/routes.dart';
import '../../state/search_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_scaffold.dart';
import 'widgets/search_field.dart';

/// Search landing page: a pinned glass field above recent searches. Submitting
/// (or tapping a recent term) seeds the [SearchProvider] and pushes the results
/// route (`'/search/results'`).
class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  void _runQuery(BuildContext context, String raw) {
    final String query = raw.trim();
    if (query.isEmpty) return;
    final SearchProvider provider = context.read<SearchProvider>();
    provider.setQuery(query);
    provider.search(query);
    context.push('${Routes.search}/${Routes.searchResults}');
  }

  @override
  Widget build(BuildContext context) {
    final List<String> history = context.watch<SearchProvider>().history;
    return AppScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: AppDimens.space8),
            const Text('Search', style: AppTypography.displayM),
            const SizedBox(height: AppDimens.space20),
            SearchField(
              hintText: 'Songs, albums, artists, playlists',
              onSubmitted: (String value) => _runQuery(context, value),
            ),
            const SizedBox(height: AppDimens.space24),
            Expanded(
              child: history.isEmpty
                  ? const _EmptyState()
                  : _RecentSearches(
                      history: history,
                      onSelected: (String term) => _runQuery(context, term),
                      onClear: () =>
                          context.read<SearchProvider>().clearHistory(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentSearches extends StatelessWidget {
  final List<String> history;
  final ValueChanged<String> onSelected;
  final VoidCallback onClear;

  const _RecentSearches({
    required this.history,
    required this.onSelected,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Text('Recent searches', style: AppTypography.label),
            const Spacer(),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClear,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: AppDimens.space8,
                  horizontal: AppDimens.space4,
                ),
                child: Text(
                  'Clear',
                  style: AppTypography.label.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.space12),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: AppDimens.space8,
              runSpacing: AppDimens.space8,
              children: <Widget>[
                for (final String term in history)
                  _RecentChip(label: term, onTap: () => onSelected(term)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RecentChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _RecentChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
        decoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(AppDimens.radiusPill),
          border: Border.all(color: AppColors.surfaceGlassBorder, width: 1),
        ),
        child: SizedBox(
          height: AppDimens.minTouch,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.history_rounded,
                size: 16,
                color: AppColors.onSurfaceFaint,
              ),
              const SizedBox(width: AppDimens.space8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.label.copyWith(
                    color: AppColors.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.search_rounded,
            size: 48,
            color: AppColors.onSurfaceFaint,
          ),
          const SizedBox(height: AppDimens.space16),
          Text(
            'Find songs, albums, artists and playlists',
            textAlign: TextAlign.center,
            style: AppTypography.label,
          ),
        ],
      ),
    );
  }
}

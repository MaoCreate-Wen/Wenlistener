import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/play_url.dart';
import '../../models/song.dart';
import '../../services/resource_cache.dart';
import '../../services/settings_store.dart';
import '../../shell/fullscreen_controller.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../player/widgets/toggle_icon_button.dart';
import '../playlist/desktop_kit.dart';
import 'account_section.dart';

/// Desktop settings body, hosted by [showSettingsDialog]. Sectioned form: 音源
/// selector → inline 账号 (per selected source) → 背景律动 → 音质 → 关于. All writes
/// go through [SettingsProvider] / the auth providers — nothing is re-implemented
/// here.
class SettingsBody extends StatelessWidget {
  const SettingsBody({super.key});

  @override
  Widget build(BuildContext context) {
    final MusicSource source =
        context.select<SettingsProvider, MusicSource>((SettingsProvider s) => s.source);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // --- 音源 -----------------------------------------------------------
        const _SettingsSection(
          title: '音源',
          subtitle: '搜索、推荐与歌单跟随所选音源',
          child: _SourceSelector(),
        ),
        const SizedBox(height: AppDimens.sectionGap),

        // --- 账号 -----------------------------------------------------------
        _SettingsSection(
          title: '账号',
          subtitle: '登录 ${dkSourceLabel(source)} 以解锁会员曲目与个人歌单',
          child: AccountSection(source: source),
        ),
        const SizedBox(height: AppDimens.sectionGap),

        // --- 播放 -----------------------------------------------------------
        const _SettingsSection(
          title: '播放',
          child: Column(
            children: <Widget>[
              _RhythmRow(),
              Divider(height: AppDimens.space24, color: AppColors.glassBorder),
              _QualityRow(),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.sectionGap),

        // --- 显示 -----------------------------------------------------------
        const _SettingsSection(
          title: '显示',
          child: Column(
            children: <Widget>[
              _FullscreenRow(),
              Divider(height: AppDimens.space24, color: AppColors.glassBorder),
              _CloseBehaviorRow(),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.sectionGap),

        // --- 缓存 -----------------------------------------------------------
        const _SettingsSection(
          title: '缓存',
          subtitle: '封面与歌词离线缓存，超出上限自动清理最久未使用的条目',
          child: Column(
            children: <Widget>[
              _CacheLimitRow(),
              Divider(height: AppDimens.space24, color: AppColors.glassBorder),
              _CacheUsageRow(),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.sectionGap),

        // --- 关于 -----------------------------------------------------------
        const _SettingsSection(
          title: '关于',
          child: _AboutRow(),
        ),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const _SettingsSection({
    required this.title,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DkSectionTitle(title: title, subtitle: subtitle),
        const SizedBox(height: AppDimens.space16),
        DkGlass(
          padding: const EdgeInsets.all(AppDimens.space20),
          child: child,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 音源 selector
// ---------------------------------------------------------------------------

class _SourceSelector extends StatelessWidget {
  const _SourceSelector();

  @override
  Widget build(BuildContext context) {
    final MusicSource active =
        context.select<SettingsProvider, MusicSource>((SettingsProvider s) => s.source);
    return Wrap(
      spacing: AppDimens.space12,
      runSpacing: AppDimens.space12,
      children: <Widget>[
        for (final MusicSource s in dkSelectableSources)
          _SourceChip(
            source: s,
            selected: s == active,
            onTap: () => context.read<SettingsProvider>().setSource(s),
          ),
      ],
    );
  }
}

class _SourceChip extends StatefulWidget {
  final MusicSource source;
  final bool selected;
  final VoidCallback onTap;

  const _SourceChip({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SourceChip> createState() => _SourceChipState();
}

class _SourceChipState extends State<_SourceChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Color accent = AppColors.accentOf(context);
    final bool sel = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 176,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space16,
            vertical: AppDimens.space16,
          ),
          decoration: BoxDecoration(
            color: sel
                ? Color.alphaBlend(accent.withValues(alpha: 0.20), AppColors.surface)
                : (_hover ? AppColors.hover : AppColors.glass),
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
            border: Border.all(
              color: sel ? accent : AppColors.glassBorder,
              width: sel ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                dkSourceIcon(widget.source),
                color: sel ? accent : AppColors.onMuted,
                size: 22,
              ),
              const SizedBox(width: AppDimens.space12),
              Expanded(
                child: Text(
                  dkSourceLabel(widget.source),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body.copyWith(
                    color: sel ? AppColors.onSurface : AppColors.onMuted,
                    fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (sel)
                Icon(Icons.check_circle_rounded, color: accent, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 背景律动 toggle
// ---------------------------------------------------------------------------

class _RhythmRow extends StatelessWidget {
  const _RhythmRow();

  @override
  Widget build(BuildContext context) {
    final bool on =
        context.select<SettingsProvider, bool>((SettingsProvider s) => s.rhythmEnabled);
    return _FormRow(
      icon: Icons.graphic_eq_rounded,
      label: '背景律动',
      hint: '歌词页背景随节拍脉动（关闭更省电）',
      control: Switch(
        value: on,
        activeThumbColor: AppColors.accentOf(context),
        onChanged: (bool v) =>
            context.read<SettingsProvider>().setRhythmEnabled(v),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 沉浸全屏 (session-only — deliberately NOT persisted in SettingsStore)
// ---------------------------------------------------------------------------

/// Enters/leaves immersive fullscreen via [FullscreenController] — the same
/// session state F11 toggles globally. The pill trigger mirrors the
/// [_QualitySelector] glass style; its label flips with the live state so the
/// row stays truthful if the user F11s while the dialog is open.
class _FullscreenRow extends StatefulWidget {
  const _FullscreenRow();

  @override
  State<_FullscreenRow> createState() => _FullscreenRowState();
}

class _FullscreenRowState extends State<_FullscreenRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: FullscreenController.isFullscreen,
      builder: (BuildContext context, bool fullscreen, _) {
        return _FormRow(
          icon: Icons.fullscreen_rounded,
          label: '沉浸全屏',
          hint: fullscreen ? '按 F11 或 Esc 退出' : '铺满整个屏幕，按 F11 退出',
          control: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: AmllBounce(
              onTap: () => FullscreenController.setFullscreen(!fullscreen),
              child: Container(
                width: 132,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.space12,
                  vertical: AppDimens.space8,
                ),
                decoration: BoxDecoration(
                  color: _hover ? AppColors.pressed : AppColors.glass,
                  borderRadius: BorderRadius.circular(AppDimens.radiusMd),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      fullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      color: AppColors.onMuted,
                      size: 20,
                    ),
                    const SizedBox(width: AppDimens.space8),
                    Text(fullscreen ? '退出全屏' : '进入全屏',
                        style: AppTypography.body),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 关闭主界面时 (window ✕ behavior — persisted)
// ---------------------------------------------------------------------------

class _CloseBehaviorRow extends StatelessWidget {
  const _CloseBehaviorRow();

  @override
  Widget build(BuildContext context) {
    return const _FormRow(
      icon: Icons.close_rounded,
      label: '关闭主界面时',
      hint: '最小化到托盘后播放继续，可从托盘菜单控制',
      control: _CloseBehaviorSelector(),
    );
  }
}

/// Same bounded glass-pill + [dkShowGlassMenu] pattern as [_QualitySelector];
/// writes go through [SettingsProvider.setCloseBehavior] (persisted, and read
/// live by the tray controller's `onWindowClose`).
class _CloseBehaviorSelector extends StatefulWidget {
  const _CloseBehaviorSelector();

  static const Map<CloseBehavior, String> _labels = <CloseBehavior, String>{
    CloseBehavior.exit: '直接退出',
    CloseBehavior.minimizeToTray: '最小化到托盘',
  };

  static const double _width = 148;

  @override
  State<_CloseBehaviorSelector> createState() => _CloseBehaviorSelectorState();
}

class _CloseBehaviorSelectorState extends State<_CloseBehaviorSelector> {
  final GlobalKey _anchor = GlobalKey();
  bool _hover = false;

  Future<void> _open(CloseBehavior current) async {
    final RenderBox? box =
        _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final Offset at = box.localToGlobal(Offset(0, box.size.height + 6));
    final CloseBehavior? picked = await dkShowGlassMenu<CloseBehavior>(
      context,
      at,
      <DkMenuEntry<CloseBehavior>>[
        for (final CloseBehavior b in CloseBehavior.values)
          DkMenuEntry<CloseBehavior>(
            value: b,
            label: _CloseBehaviorSelector._labels[b] ?? b.name,
            selected: b == current,
          ),
      ],
      // Wider than the trigger pill: the popup row also fits the trailing
      // check icon, which would otherwise ellipsize 最小化到托盘.
      width: _CloseBehaviorSelector._width + 28,
    );
    if (picked != null && mounted) {
      context.read<SettingsProvider>().setCloseBehavior(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final CloseBehavior b = context.select<SettingsProvider, CloseBehavior>(
        (SettingsProvider s) => s.closeBehavior);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AmllBounce(
        onTap: () => _open(b),
        child: Container(
          key: _anchor,
          width: _CloseBehaviorSelector._width,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space12,
            vertical: AppDimens.space8,
          ),
          decoration: BoxDecoration(
            color: _hover ? AppColors.pressed : AppColors.glass,
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _CloseBehaviorSelector._labels[b] ?? b.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body,
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              const Icon(Icons.expand_more_rounded,
                  color: AppColors.onMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 音质 dropdown
// ---------------------------------------------------------------------------

class _QualityRow extends StatelessWidget {
  const _QualityRow();

  @override
  Widget build(BuildContext context) {
    return const _FormRow(
      icon: Icons.high_quality_rounded,
      label: '音质',
      hint: '新解析的曲目使用该音质（已缓存的保持原样）',
      control: _QualitySelector(),
    );
  }
}

/// Compact, **bounded-width** 音质 selector. Replaces the bare [DropdownButton]
/// (which stretched into a full-width 大长条 inside the [Row]) with a fixed-width
/// glass pill that opens a white frosted-glass popup ([dkShowGlassMenu]); neither
/// the trigger nor the menu can grow full-width. Wiring is unchanged
/// ([SettingsProvider.setAudioQuality] over [AudioLevel]).
class _QualitySelector extends StatefulWidget {
  const _QualitySelector();

  static const Map<AudioLevel, String> _labels = <AudioLevel, String>{
    AudioLevel.standard: '标准',
    AudioLevel.higher: '较高',
    AudioLevel.exhigh: '极高',
    AudioLevel.lossless: '无损',
    AudioLevel.hires: 'Hi-Res',
  };

  static const double _width = 132;

  @override
  State<_QualitySelector> createState() => _QualitySelectorState();
}

class _QualitySelectorState extends State<_QualitySelector> {
  final GlobalKey _anchor = GlobalKey();
  bool _hover = false;

  Future<void> _open(AudioLevel current) async {
    final RenderBox? box =
        _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    // Anchor the popup just below the trigger's bottom-left.
    final Offset at = box.localToGlobal(Offset(0, box.size.height + 6));
    final AudioLevel? picked = await dkShowGlassMenu<AudioLevel>(
      context,
      at,
      <DkMenuEntry<AudioLevel>>[
        for (final AudioLevel level in AudioLevel.values)
          DkMenuEntry<AudioLevel>(
            value: level,
            label: _QualitySelector._labels[level] ?? level.name,
            selected: level == current,
          ),
      ],
      width: _QualitySelector._width,
    );
    if (picked != null && mounted) {
      context.read<SettingsProvider>().setAudioQuality(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AudioLevel q = context.select<SettingsProvider, AudioLevel>(
        (SettingsProvider s) => s.audioQuality);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AmllBounce(
        onTap: () => _open(q),
        child: Container(
          key: _anchor,
          width: _QualitySelector._width,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space12,
            vertical: AppDimens.space8,
          ),
          decoration: BoxDecoration(
            color: _hover ? AppColors.pressed : AppColors.glass,
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _QualitySelector._labels[q] ?? q.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body,
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              const Icon(Icons.expand_more_rounded,
                  color: AppColors.onMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 缓存 (disk cache budget + usage / clear)
// ---------------------------------------------------------------------------

class _CacheLimitRow extends StatelessWidget {
  const _CacheLimitRow();

  @override
  Widget build(BuildContext context) {
    return const _FormRow(
      icon: Icons.sd_storage_rounded,
      label: '缓存上限',
      hint: '超过上限时按最久未使用自动清理（不缓存音频流）',
      control: _CacheLimitSelector(),
    );
  }
}

/// Same bounded glass-pill + [dkShowGlassMenu] pattern as [_QualitySelector];
/// choices come from [kCacheMaxBytesChoices], writes go through
/// [SettingsProvider.setCacheMaxBytes] (persisted + pushed into the live
/// [ResourceCache] so eviction reacts immediately).
class _CacheLimitSelector extends StatefulWidget {
  const _CacheLimitSelector();

  static const double _width = 132;

  @override
  State<_CacheLimitSelector> createState() => _CacheLimitSelectorState();
}

class _CacheLimitSelectorState extends State<_CacheLimitSelector> {
  final GlobalKey _anchor = GlobalKey();
  bool _hover = false;

  Future<void> _open(int current) async {
    final RenderBox? box =
        _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final Offset at = box.localToGlobal(Offset(0, box.size.height + 6));
    final int? picked = await dkShowGlassMenu<int>(
      context,
      at,
      <DkMenuEntry<int>>[
        for (final int bytes in kCacheMaxBytesChoices)
          DkMenuEntry<int>(
            value: bytes,
            label: cacheBytesLabel(bytes),
            selected: bytes == current,
          ),
      ],
      width: _CacheLimitSelector._width,
    );
    if (picked != null && mounted) {
      context.read<SettingsProvider>().setCacheMaxBytes(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final int bytes = context
        .select<SettingsProvider, int>((SettingsProvider s) => s.cacheMaxBytes);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AmllBounce(
        onTap: () => _open(bytes),
        child: Container(
          key: _anchor,
          width: _CacheLimitSelector._width,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space12,
            vertical: AppDimens.space8,
          ),
          decoration: BoxDecoration(
            color: _hover ? AppColors.pressed : AppColors.glass,
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  cacheBytesLabel(bytes),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body,
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              const Icon(Icons.expand_more_rounded,
                  color: AppColors.onMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// 已用空间 display (computed async on open / after clearing) + 清空缓存 button.
class _CacheUsageRow extends StatefulWidget {
  const _CacheUsageRow();

  @override
  State<_CacheUsageRow> createState() => _CacheUsageRowState();
}

class _CacheUsageRowState extends State<_CacheUsageRow> {
  Future<int>? _usage;
  bool _clearing = false;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _usage = ResourceCache.instance.totalBytes();
  }

  Future<void> _clear() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    await ResourceCache.instance.clear();
    if (!mounted) return;
    setState(() {
      _clearing = false;
      _usage = ResourceCache.instance.totalBytes();
    });
  }

  static String _fmt(int bytes) {
    if (bytes >= (1 << 30)) {
      return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    }
    if (bytes >= (1 << 20)) {
      return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    return _FormRow(
      icon: Icons.cleaning_services_rounded,
      label: '已用空间',
      hint: '位于系统临时目录，可随时清空',
      control: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FutureBuilder<int>(
            future: _usage,
            builder: (BuildContext context, AsyncSnapshot<int> snap) => Text(
              snap.hasData ? _fmt(snap.data!) : '计算中…',
              style: AppTypography.body.copyWith(color: AppColors.onMuted),
            ),
          ),
          const SizedBox(width: AppDimens.space16),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: AmllBounce(
              onTap: _clear,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.space16,
                  vertical: AppDimens.space8,
                ),
                decoration: BoxDecoration(
                  color: _hover ? AppColors.pressed : AppColors.glass,
                  borderRadius: BorderRadius.circular(AppDimens.radiusMd),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: _clearing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.onMuted,
                        ),
                      )
                    : Text('清空缓存', style: AppTypography.body),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.glass,
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.graphic_eq_rounded,
              color: AppColors.accentPlay, size: 26),
        ),
        const SizedBox(width: AppDimens.space16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('WenListener Desktop', style: AppTypography.titleM),
            const SizedBox(height: 2),
            Text('版本 1.0.0 · 网易云 / QQ / 酷狗 / 酷我',
                style: AppTypography.caption),
          ],
        ),
      ],
    );
  }
}

/// A label-left / control-right form row shared by the play settings.
class _FormRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final Widget control;

  const _FormRow({
    required this.icon,
    required this.label,
    this.hint,
    required this.control,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, color: AppColors.onMuted, size: 22),
        const SizedBox(width: AppDimens.space16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: AppTypography.body),
              if (hint != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(hint!, style: AppTypography.caption),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppDimens.space16),
        control,
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/play_url.dart';
import '../../models/song.dart';
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
          child: _FullscreenRow(),
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

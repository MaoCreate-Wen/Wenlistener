import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import 'buttons.dart';

/// Speaker icon + thin draggable volume track wired to [PlayerProvider.volume] /
/// [setVolume]. The mute icon toggles between 0 and the previous level. Selects
/// only `volume` so it doesn't rebuild on position ticks.
class VolumeControl extends StatefulWidget {
  final double width;
  const VolumeControl({super.key, this.width = 96});

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  double _lastNonZero = 0.8;

  @override
  Widget build(BuildContext context) {
    final double volume = context.select((PlayerProvider p) => p.volume);
    final PlayerProvider player = context.read<PlayerProvider>();
    if (volume > 0) _lastNonZero = volume;

    final IconData icon = volume <= 0
        ? Icons.volume_off_rounded
        : volume < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconHoverButton(
          icon: icon,
          size: 32,
          iconSize: 20,
          tooltip: volume <= 0 ? '取消静音' : '静音',
          onTap: () => player.setVolume(volume <= 0 ? _lastNonZero : 0),
        ),
        SizedBox(
          width: widget.width,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: Colors.white.withValues(alpha: 0.7),
              inactiveTrackColor: AppColors.glassBorder,
              thumbColor: AppColors.onSurface,
              overlayColor: Colors.white.withValues(alpha: 0.12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: volume.clamp(0.0, 1.0),
              onChanged: player.setVolume,
            ),
          ),
        ),
      ],
    );
  }
}

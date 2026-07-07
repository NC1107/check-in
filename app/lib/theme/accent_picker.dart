import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';
import 'accent.dart';
import 'tokens.dart';

/// A row of accent swatches bound to [accentProvider]. Tapping one recolors the whole
/// app live and persists the choice per-device. Shared by the Appearance settings and
/// the signup profile step so the two never drift.
class AccentPicker extends ConsumerWidget {
  const AccentPicker({super.key, this.swatchSize = 62});

  final double swatchSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(accentProvider);
    return Wrap(
      spacing: 18,
      runSpacing: 16,
      children: [
        for (final p in kAccentPresets)
          _Swatch(
            palette: p,
            selected: p.id == selected.id,
            size: swatchSize,
            onTap: () => ref.read(accentProvider.notifier).select(p),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.palette,
    required this.selected,
    required this.size,
    required this.onTap,
  });

  final AccentPalette palette;
  final bool selected;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: palette.base,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? kFgPrimary : kBorder,
                width: selected ? 3 : 1,
              ),
            ),
            child: selected ? Icon(Icons.check, color: palette.onAccent, size: size * 0.45) : null,
          ),
          const SizedBox(height: 8),
          Text(
            palette.name,
            style: TextStyle(
              color: selected ? kFgPrimary : kFgSecondary,
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

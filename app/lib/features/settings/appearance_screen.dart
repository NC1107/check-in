import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';

/// Pick the app's accent color from a curated set of presets. The choice persists
/// per-device and recolors the whole app live.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(accentProvider);
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: const Text('Appearance',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          const Text('Accent color',
              style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 4),
          const Text('Used for buttons, links, and highlights across the app.',
              style: TextStyle(color: kFgMuted, fontSize: 13)),
          const SizedBox(height: 22),
          Wrap(
            spacing: 18,
            runSpacing: 18,
            children: [
              for (final p in kAccentPresets)
                _Swatch(
                  palette: p,
                  selected: p.id == selected.id,
                  onTap: () => ref.read(accentProvider.notifier).select(p),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.palette, required this.selected, required this.onTap});

  final AccentPalette palette;
  final bool selected;
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
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: palette.base,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? kFgPrimary : kBorder,
                width: selected ? 3 : 1,
              ),
            ),
            child: selected ? Icon(Icons.check, color: palette.onAccent, size: 28) : null,
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

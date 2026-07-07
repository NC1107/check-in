import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/accent_picker.dart';
import '../../theme/tokens.dart';

/// Pick the app's accent color from a curated set of presets. The choice persists
/// per-device and recolors the whole app live.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        children: const [
          Text('Accent color',
              style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
          SizedBox(height: 4),
          Text('Used for buttons, links, and highlights across the app.',
              style: TextStyle(color: kFgMuted, fontSize: 13)),
          SizedBox(height: 22),
          AccentPicker(),
        ],
      ),
    );
  }
}

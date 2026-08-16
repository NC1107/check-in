import 'package:flutter/material.dart';

import '../../theme/accent.dart';
import '../../theme/tokens.dart';

/// The Gallery/Camera row under the composer.
///
/// The row stays on screen in every state, a clip attached included. It used to be hidden
/// as soon as a clip was picked, so the only route back to a picker was the clip tile's
/// small remove control - swapping a clip meant first working out that the tile had to go.
///
/// A check-in is still one clip or a set of photos, so picking again while a clip is
/// attached asks to replace it first and, once confirmed, clears the clip before the picker
/// opens. With photos attached the buttons keep their add-more behaviour and ask nothing.
class ComposeMediaButtons extends StatelessWidget {
  const ComposeMediaButtons({
    super.key,
    required this.hasClip,
    required this.hasPhotos,
    required this.onGallery,
    required this.onCamera,
    required this.onReplaceClip,
  });

  final bool hasClip;
  final bool hasPhotos;

  /// Opens the gallery picker (photos or one clip).
  final Future<void> Function() onGallery;

  /// Opens the camera chooser (photo or clip).
  final Future<void> Function() onCamera;

  /// Drops the attached clip. Run after a confirmed replace and before the picker opens, so
  /// a cancelled pick leaves the composer holding the clip it already had.
  final VoidCallback onReplaceClip;

  Future<void> _pick(BuildContext context, Future<void> Function() open) async {
    if (hasClip) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kBgSurface,
          title: const Text('Replace the current clip?', style: TextStyle(color: kFgPrimary)),
          content: const Text(
            'A check-in holds one clip or a set of photos. Picking again drops the clip you '
            'attached.',
            style: TextStyle(color: kFgSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: kFgSecondary)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: ctx.accent,
                foregroundColor: ctx.onAccent,
              ),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true) return;
      onReplaceClip();
    }
    await open();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _button(
            context,
            Icons.photo_library_outlined,
            hasPhotos ? 'Add more' : 'Gallery',
            () => _pick(context, onGallery),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _button(
            context,
            Icons.photo_camera_outlined,
            'Camera',
            () => _pick(context, onCamera),
          ),
        ),
      ],
    );
  }

  Widget _button(BuildContext context, IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, color: context.accent, size: 19),
      label: Text(label,
          style: const TextStyle(color: kFgSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: kBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(vertical: 11),
      ),
    );
  }
}

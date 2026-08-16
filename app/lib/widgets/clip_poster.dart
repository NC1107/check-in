import 'package:flutter/material.dart';

import '../api/models.dart';
import 'auth_image.dart';

/// A clip shown as a still: its poster frame under a play badge and its length.
///
/// This is what a clip looks like before anything plays - in the feed until autoplay takes
/// the slot, in the full-screen viewer until the first frame decodes, and everywhere a
/// player could not be had at all. It is a separate widget from the players themselves so
/// the still and the picture can be stacked without one rebuilding the other.
class ClipPoster extends StatelessWidget {
  const ClipPoster({
    super.key,
    required this.media,
    this.groupId,
    this.fit = BoxFit.cover,
    this.onImageResolved,
    this.showOverlays = true,
  });

  final PostMedia media;

  /// The connected group the media belongs to (null = the current group). See [AuthImage].
  final String? groupId;
  final BoxFit fit;

  /// Reports the intrinsic size of the still once it has decoded (see [AuthImage]).
  final ValueChanged<ImageInfo>? onImageResolved;

  /// The play badge and length pill. Dropped while the clip is actually playing over this,
  /// where a play glyph would be a lie and the length is already running down.
  final bool showOverlays;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // A clip's own bytes are not an image. The server serves the clip itself when it
        // has no poster, so asking for one anyway would render a broken-image icon; a flat
        // backdrop under the badge says "clip" without pretending to show it.
        if (media.hasPoster)
          AuthImage(
            mediaId: media.id,
            groupId: groupId,
            fit: fit,
            variant: 'poster',
            onImageResolved: onImageResolved,
          )
        else
          const ColoredBox(color: Color(0xFF14161A)),
        if (showOverlays) ...[
          const Center(child: _PlayBadge()),
          if (media.durationLabel.isNotEmpty)
            Positioned(bottom: 8, left: 8, child: _DurationPill(media.durationLabel)),
        ],
      ],
    );
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.5),
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: 30,
        semanticLabel: 'Video',
      ),
    );
  }
}

class _DurationPill extends StatelessWidget {
  const _DurationPill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

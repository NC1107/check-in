import 'package:flutter/material.dart';

import '../api/models.dart';
import 'auth_image.dart';

/// The [Hero] tag a feed photo and its full-screen counterpart share, so tapping the photo
/// flies it into the viewer. Scoped by group id as well as media id because the same media
/// id can surface under two connected groups, and two heroes sharing a tag on one screen
/// would crash.
String photoHeroTag(String? groupId, int mediaId) => 'photo-$groupId-$mediaId';

/// One post attachment, rendered as a still. A photo or gif renders directly (gifs animate
/// on their own); a clip renders its poster frame under a play badge and its length.
///
/// Nothing here plays: there is no player in the app yet, so the badge marks the media as
/// a clip rather than inviting a tap that would do nothing. Both the feed carousel and the
/// full-screen viewer render through this, so a clip can never quietly reach one of them
/// as a "photo" that fails to decode.
class MediaFrame extends StatelessWidget {
  const MediaFrame({
    super.key,
    required this.media,
    this.groupId,
    this.fit = BoxFit.cover,
    this.onImageResolved,
  });

  final PostMedia media;

  /// The connected group the media belongs to (null = the current group). See [AuthImage].
  final String? groupId;
  final BoxFit fit;

  /// Reports the intrinsic size of the still once it has decoded (see [AuthImage]).
  final ValueChanged<ImageInfo>? onImageResolved;

  @override
  Widget build(BuildContext context) {
    if (!media.isVideo) {
      return AuthImage(
        mediaId: media.id,
        groupId: groupId,
        fit: fit,
        onImageResolved: onImageResolved,
      );
    }
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
        const Center(child: _PlayBadge()),
        if (media.durationLabel.isNotEmpty)
          Positioned(bottom: 8, left: 8, child: _DurationPill(media.durationLabel)),
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

import 'package:flutter/material.dart';

import '../api/models.dart';
import 'auth_image.dart';
import 'clip_poster.dart';
import 'feed_autoplay.dart';
import 'feed_clip.dart';

/// The [Hero] tag a feed photo and its full-screen counterpart share, so tapping the photo
/// flies it into the viewer. Scoped by group id as well as media id because the same media
/// id can surface under two connected groups, and two heroes sharing a tag on one screen
/// would crash.
String photoHeroTag(String? groupId, int mediaId) => 'photo-$groupId-$mediaId';

/// One post attachment. A photo or gif renders directly (gifs animate on their own); a clip
/// renders through [ClipPoster], and inside a [FeedAutoplayScope] through [FeedClip], which
/// plays it muted while it is the clip on screen.
///
/// Both the feed carousel and the full-screen viewer render through this, so a clip can
/// never quietly reach one of them as a "photo" that fails to decode. Whether a clip plays
/// here is not this widget's call: it plays where a feed has put an autoplay scope overhead,
/// and shows its poster everywhere else.
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
    final autoplay = FeedAutoplayScope.maybeOf(context);
    if (autoplay == null) {
      return ClipPoster(
        media: media,
        groupId: groupId,
        fit: fit,
        onImageResolved: onImageResolved,
      );
    }
    return FeedClip(
      media: media,
      groupId: groupId,
      fit: fit,
      autoplay: autoplay,
      onImageResolved: onImageResolved,
    );
  }
}

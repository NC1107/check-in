import 'package:flutter/material.dart';

import '../api/models.dart';
import 'media_frame.dart';

// Post images size to their own aspect ratio, clamped so a very tall or very wide photo
// still fits the feed: portrait no taller than 4:5, landscape no wider than 1.91:1.
const _minAspect = 4 / 5; // tallest (portrait)
const _maxAspect = 1.91; // widest (landscape)
const _defaultAspect = 4 / 3; // used while the image dimensions are still loading

/// Renders a post's attachment(s), sizing itself. A single one adopts its own (clamped)
/// aspect ratio so portrait photos aren't center-cropped; several become a swipeable
/// carousel with page dots and a counter pill at a fixed 4:3. A clip shows as its poster
/// frame with a play badge (see [MediaFrame]).
///
/// Tap and double-tap are handled here (not by the caller) so the currently-shown media
/// id is known: a single tap reports the visible image via [onImageTap] (e.g. to open a
/// full-screen viewer), a double-tap fires [onDoubleTap] (e.g. like). Centralising both in
/// one detector avoids the gesture-arena conflicts of nesting tap handlers.
class PostImageCarousel extends StatefulWidget {
  const PostImageCarousel({
    super.key,
    required this.media,
    this.groupId,
    this.onImageTap,
    this.onDoubleTap,
  });

  final List<PostMedia> media;

  /// The connected group the media belongs to (null = the current group).
  final String? groupId;

  /// Called with the currently-visible media id when the photo is tapped.
  final void Function(int mediaId)? onImageTap;

  /// Called when the photo is double-tapped (e.g. to like).
  final VoidCallback? onDoubleTap;

  @override
  State<PostImageCarousel> createState() => _PostImageCarouselState();
}

class _PostImageCarouselState extends State<PostImageCarousel> {
  final _ctrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    if (media.isEmpty) return const SizedBox.shrink();
    final content = media.length == 1 ? _single(media) : _carousel(media);
    if (widget.onImageTap == null && widget.onDoubleTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onImageTap == null
          ? null
          : () => widget.onImageTap!(media[_page.clamp(0, media.length - 1)].id),
      onDoubleTap: widget.onDoubleTap,
      child: content,
    );
  }

  Widget _single(List<PostMedia> media) =>
      _AdaptiveImage(media: media.first, groupId: widget.groupId);

  Widget _carousel(List<PostMedia> media) {
    return AspectRatio(
      aspectRatio: _defaultAspect,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _ctrl,
            itemCount: media.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => MediaFrame(media: media[i], groupId: widget.groupId),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(9999),
              ),
              child: Text('${_page + 1}/${media.length}',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ),
          Positioned(
            bottom: 8,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < media.length; i++)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: i == _page ? Colors.white : Colors.white.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single attachment that adopts its own aspect ratio (clamped to [_minAspect] ..
/// [_maxAspect]) so portrait photos aren't center-cropped to a fixed box. The server's
/// stored dimensions size the box immediately; the decoded size then confirms or corrects
/// it (a server predating stored dimensions reports none). Reading that size off the
/// still [MediaFrame] is already displaying - rather than a second, separate resolve of
/// the same url - means a fetch/decode hiccup can't leave the box silently and permanently
/// stuck at the default: if the image fails, [AuthImage] shows its own error state instead
/// of this ever being asked for a size at all.
class _AdaptiveImage extends StatefulWidget {
  const _AdaptiveImage({required this.media, this.groupId});

  final PostMedia media;
  final String? groupId;

  @override
  State<_AdaptiveImage> createState() => _AdaptiveImageState();
}

class _AdaptiveImageState extends State<_AdaptiveImage> {
  double? _ratio; // intrinsic width / height, once something has decoded

  void _onImage(ImageInfo info) {
    final r = info.image.width / info.image.height;
    if (mounted && r != _ratio) setState(() => _ratio = r);
  }

  @override
  Widget build(BuildContext context) {
    final known = _ratio ?? widget.media.aspectRatio ?? _defaultAspect;
    return AspectRatio(
      aspectRatio: known.clamp(_minAspect, _maxAspect).toDouble(),
      child: MediaFrame(media: widget.media, groupId: widget.groupId, onImageResolved: _onImage),
    );
  }
}

import 'package:flutter/material.dart';

import 'auth_image.dart';

// Post images size to their own aspect ratio, clamped so a very tall or very wide photo
// still fits the feed: portrait no taller than 4:5, landscape no wider than 1.91:1.
const _minAspect = 4 / 5; // tallest (portrait)
const _maxAspect = 1.91; // widest (landscape)
const _defaultAspect = 4 / 3; // used while the image dimensions are still loading

/// Renders a post's image(s), sizing itself. A single image adopts its own (clamped)
/// aspect ratio so portrait photos aren't center-cropped; multiple images become a
/// swipeable carousel with page dots and a counter pill at a fixed 4:3.
///
/// Tap and double-tap are handled here (not by the caller) so the currently-shown media
/// id is known: a single tap reports the visible image via [onImageTap] (e.g. to open a
/// full-screen viewer), a double-tap fires [onDoubleTap] (e.g. like). Centralising both in
/// one detector avoids the gesture-arena conflicts of nesting tap handlers.
class PostImageCarousel extends StatefulWidget {
  const PostImageCarousel({
    super.key,
    required this.mediaIds,
    this.groupId,
    this.onImageTap,
    this.onDoubleTap,
  });

  final List<int> mediaIds;

  /// The connected group the media ids belong to (null = the current group).
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
    final ids = widget.mediaIds;
    if (ids.isEmpty) return const SizedBox.shrink();
    final content = ids.length == 1 ? _single(ids) : _carousel(ids);
    if (widget.onImageTap == null && widget.onDoubleTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onImageTap == null
          ? null
          : () => widget.onImageTap!(ids[_page.clamp(0, ids.length - 1)]),
      onDoubleTap: widget.onDoubleTap,
      child: content,
    );
  }

  Widget _single(List<int> ids) => _AdaptiveImage(mediaId: ids.first, groupId: widget.groupId);

  Widget _carousel(List<int> ids) {
    return AspectRatio(
      aspectRatio: _defaultAspect,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _ctrl,
            itemCount: ids.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => AuthImage(mediaId: ids[i], groupId: widget.groupId),
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
              child: Text('${_page + 1}/${ids.length}',
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
                for (var i = 0; i < ids.length; i++)
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

/// A single post image that adopts its own aspect ratio (clamped to [_minAspect] ..
/// [_maxAspect]) so portrait photos aren't center-cropped to a fixed box. Reads the
/// image's intrinsic size off [AuthImage] once it has actually decoded (see
/// [AuthImage.onImageResolved]), then re-lays out; until then it uses the default aspect
/// so the card doesn't jump. Sizing this way - rather than a second, separate resolve of
/// the same url - means a fetch/decode hiccup can't leave the box silently and permanently
/// stuck at the default: if the image fails, [AuthImage] shows its own error state instead
/// of this ever being asked for a size at all.
class _AdaptiveImage extends StatefulWidget {
  const _AdaptiveImage({required this.mediaId, this.groupId});

  final int mediaId;
  final String? groupId;

  @override
  State<_AdaptiveImage> createState() => _AdaptiveImageState();
}

class _AdaptiveImageState extends State<_AdaptiveImage> {
  double? _ratio; // intrinsic width / height

  void _onImage(ImageInfo info) {
    final r = info.image.width / info.image.height;
    if (mounted && r != _ratio) setState(() => _ratio = r);
  }

  @override
  Widget build(BuildContext context) {
    final ratio = (_ratio ?? _defaultAspect).clamp(_minAspect, _maxAspect).toDouble();
    return AspectRatio(
      aspectRatio: ratio,
      child: AuthImage(mediaId: widget.mediaId, groupId: widget.groupId, onImageResolved: _onImage),
    );
  }
}

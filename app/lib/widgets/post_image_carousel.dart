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
/// carousel with page dots and a counter pill, sized once by the first photo's clamped
/// ratio so the card keeps one height across swipes. A clip shows as its poster frame with
/// a play badge (see [MediaFrame]).
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
      _hero(media.first, _AdaptiveImage(media: media.first, groupId: widget.groupId));

  // Wrap real images (gifs included) so a tapped feed photo flies into the full-screen
  // viewer, which shares the same [photoHeroTag]. A clip shows a poster, not the photo
  // itself, so it doesn't hero.
  Widget _hero(PostMedia m, Widget child) =>
      m.isImage ? Hero(tag: photoHeroTag(widget.groupId, m.id), child: child) : child;

  Widget _carousel(List<PostMedia> media) {
    return AspectRatio(
      aspectRatio: feedAspectFor(media.first, widget.groupId),
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _ctrl,
            itemCount: media.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) =>
                _hero(media[i], MediaFrame(media: media[i], groupId: widget.groupId)),
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

/// Intrinsic ratios learned from decoded images, for media the server reported no
/// dimensions for (rows stored before dimensions were kept). A feed card is disposed and
/// rebuilt as it scrolls or the viewer closes; without this memory it would restart at the
/// default box and visibly jump to the real shape once the cached image resolved again.
final _decodedRatios = <String, double>{};

String _ratioKey(String? groupId, int mediaId) => '$groupId/$mediaId';

/// The box ratio for [media] before any pixel has decoded: what the server stored, else
/// what an earlier decode taught us, else the default. Deterministic from the first frame,
/// so the loading placeholder is already the final size.
double feedAspectFor(PostMedia media, String? groupId) =>
    (media.aspectRatio ?? _decodedRatios[_ratioKey(groupId, media.id)] ?? _defaultAspect)
        .clamp(_minAspect, _maxAspect)
        .toDouble();

/// A single attachment that adopts its own aspect ratio (clamped to [_minAspect] ..
/// [_maxAspect]) so portrait photos aren't center-cropped to a fixed box. Server-stored
/// dimensions are authoritative; the decoded size is only consulted when the server has
/// none, so a decode landing late (for instance after returning from the full-screen
/// viewer) can never resize a card that already has a final shape.
class _AdaptiveImage extends StatefulWidget {
  const _AdaptiveImage({required this.media, this.groupId});

  final PostMedia media;
  final String? groupId;

  @override
  State<_AdaptiveImage> createState() => _AdaptiveImageState();
}

class _AdaptiveImageState extends State<_AdaptiveImage> {
  void _onImage(ImageInfo info) {
    if (widget.media.aspectRatio != null) return;
    final key = _ratioKey(widget.groupId, widget.media.id);
    final r = info.image.width / info.image.height;
    if (_decodedRatios[key] == r) return;
    _decodedRatios[key] = r;
    // The callback can fire synchronously from inside a build (an already-cached image).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: feedAspectFor(widget.media, widget.groupId),
      child: MediaFrame(
        media: widget.media,
        groupId: widget.groupId,
        onImageResolved: _onImage,
      ),
    );
  }
}

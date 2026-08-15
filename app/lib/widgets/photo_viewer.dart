import 'package:flutter/material.dart';

import '../api/models.dart';
import 'media_frame.dart';

/// Full-screen, pinch-to-zoom viewer for one or more attachments (e.g. a profile photo, or
/// all the media on a multi-image check-in). A clip shows as its poster frame with a play
/// badge and cannot be played here yet. Opened by tapping an image. Swipe left/right
/// pages between photos (disabled while the current photo is zoomed, so panning a zoomed
/// photo doesn't also flip the page); swiping up or down dismisses, the close button, or
/// the system back gesture; double-tap toggles between fit-to-screen and a 2.5x zoom
/// centred on the tap. Swipe-to-dismiss is disabled while zoomed, so a drag then pans the
/// enlarged image instead.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({
    super.key,
    required this.media,
    this.initialIndex = 0,
    this.groupId,
  });

  /// Every attachment reachable from this viewer (e.g. all of a post's media). A
  /// single-photo context (a profile picture) passes a one-element list, built with
  /// [PostMedia.images].
  final List<PostMedia> media;

  /// Which photo to open on, as an index into [media].
  final int initialIndex;

  /// The connected group the media belongs to (null = the current group), so the
  /// authenticated request and cache key resolve to the right server. See [MediaFrame].
  final String? groupId;

  /// Pushes the viewer over everything (above the bottom nav). The backdrop is painted by
  /// the viewer itself so it can fade as the photo is dragged away, so the route barrier
  /// stays transparent.
  static Future<void> open(
    BuildContext context, {
    required List<PostMedia> media,
    int initialIndex = 0,
    String? groupId,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) =>
            PhotoViewerScreen(media: media, initialIndex: initialIndex, groupId: groupId),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> with SingleTickerProviderStateMixin {
  late final _pageCtrl = PageController(initialPage: widget.initialIndex);
  // Constructed eagerly in initState (not a lazy `late final = expr`): its vsync ticker
  // does an ancestor lookup, which is only safe while the element is mounted. A session
  // that closes the viewer without ever dragging would otherwise touch this for the first
  // time from dispose() - after the element has started unmounting - and crash.
  late final AnimationController _reset;
  late int _page = widget.initialIndex;
  // Whether the currently-visible photo is zoomed - gates both page-swiping (so panning a
  // zoomed photo doesn't also flip to the next one) and swipe-to-dismiss.
  bool _zoomed = false;
  double _dragDy = 0;

  // How far the photo must travel (or how fast) before release dismisses instead of
  // springing back.
  static const _dismissDistance = 130.0;
  static const _dismissVelocity = 1000.0;

  @override
  void initState() {
    super.initState();
    _reset = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _reset.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) => _reset.stop();

  void _onDragUpdate(DragUpdateDetails d) => setState(() => _dragDy += d.delta.dy);

  void _onDragEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dy;
    if (_dragDy.abs() > _dismissDistance || v.abs() > _dismissVelocity) {
      Navigator.of(context).pop();
      return;
    }
    final from = _dragDy;
    final anim = Tween(begin: from, end: 0.0).animate(
      CurvedAnimation(parent: _reset, curve: Curves.easeOut),
    );
    void tick() => setState(() => _dragDy = anim.value);
    anim.addListener(tick);
    _reset.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    final multi = widget.media.length > 1;
    // Fade the backdrop and ease the photo down as it is dragged, but never below 0.35 so
    // the photo stays legible until release.
    final progress = (_dragDy.abs() / (height * 0.5)).clamp(0.0, 1.0);
    final backdrop = 1.0 - progress * 0.65;
    final scale = 1.0 - progress * 0.08;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: backdrop))),
          Positioned.fill(
            child: GestureDetector(
              onVerticalDragStart: _zoomed ? null : _onDragStart,
              onVerticalDragUpdate: _zoomed ? null : _onDragUpdate,
              onVerticalDragEnd: _zoomed ? null : _onDragEnd,
              child: Transform.translate(
                offset: Offset(0, _dragDy),
                child: Transform.scale(
                  scale: scale,
                  child: PageView.builder(
                    controller: _pageCtrl,
                    physics:
                        _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                    itemCount: widget.media.length,
                    onPageChanged: (i) => setState(() {
                      _page = i;
                      _zoomed = false; // a freshly-shown page always starts unzoomed
                    }),
                    itemBuilder: (_, i) => _ZoomablePhoto(
                      media: widget.media[i],
                      groupId: widget.groupId,
                      onZoomChanged: (z) {
                        if (i == _page) setState(() => _zoomed = z);
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          if (multi)
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(9999),
                    ),
                    child: Text('${_page + 1}/${widget.media.length}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One pinch-to-zoom, double-tap-to-zoom photo inside the viewer's [PageView]. Owns its
/// own transform so zoom resets when swiping to a different photo, and reports zoom
/// changes up so the parent can gate page-swiping and swipe-to-dismiss.
class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({required this.media, required this.onZoomChanged, this.groupId});

  final PostMedia media;
  final String? groupId;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto> {
  final _controller = TransformationController();
  Offset? _doubleTapPos;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransform);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransform);
    _controller.dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      _zoomed = zoomed;
      widget.onZoomChanged(zoomed);
    }
  }

  void _handleDoubleTap() {
    const scale = 2.5;
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.01;
    final pos = _doubleTapPos;
    if (zoomed || pos == null) {
      _controller.value = Matrix4.identity();
    } else {
      // Scale about the tapped point: map p -> scale*p + t, with t chosen so the tap
      // stays put. Built column-major to avoid the deprecated Matrix4.translate/scale.
      final tx = -pos.dx * (scale - 1);
      final ty = -pos.dy * (scale - 1);
      _controller.value = Matrix4(
        scale, 0, 0, 0, //
        0, scale, 0, 0, //
        0, 0, 1, 0, //
        tx, ty, 0, 1, //
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1,
        maxScale: 5,
        child: SizedBox.expand(
          child: MediaFrame(media: widget.media, groupId: widget.groupId, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

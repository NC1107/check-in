import 'package:flutter/material.dart';

import 'auth_image.dart';

/// Full-screen, pinch-to-zoom viewer for a single media id (e.g. a profile photo or a
/// post image). Opened by tapping the image. Dismissed by swiping the photo up or down,
/// the close button, or the system back gesture; double-tap toggles between fit-to-screen
/// and a 2.5x zoom centred on the tap. Swipe-to-dismiss is disabled while zoomed, so a
/// drag then pans the enlarged image instead.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({super.key, required this.mediaId, this.groupId});

  final int mediaId;

  /// The connected group the media id belongs to (null = the current group), so the
  /// authenticated request and cache key resolve to the right server. See [AuthImage].
  final String? groupId;

  /// Pushes the viewer over everything (above the bottom nav). The backdrop is painted by
  /// the viewer itself so it can fade as the photo is dragged away, so the route barrier
  /// stays transparent.
  static Future<void> open(BuildContext context, {required int mediaId, String? groupId}) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => PhotoViewerScreen(mediaId: mediaId, groupId: groupId),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> with SingleTickerProviderStateMixin {
  final _controller = TransformationController();
  late final AnimationController _reset =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 200));

  Offset? _doubleTapPos;
  bool _zoomed = false;
  double _dragDy = 0;

  // How far the photo must travel (or how fast) before release dismisses instead of
  // springing back.
  static const _dismissDistance = 130.0;
  static const _dismissVelocity = 1000.0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransform);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransform);
    _controller.dispose();
    _reset.dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
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
              onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
              onDoubleTap: _handleDoubleTap,
              onVerticalDragStart: _zoomed ? null : _onDragStart,
              onVerticalDragUpdate: _zoomed ? null : _onDragUpdate,
              onVerticalDragEnd: _zoomed ? null : _onDragEnd,
              child: Transform.translate(
                offset: Offset(0, _dragDy),
                child: Transform.scale(
                  scale: scale,
                  child: InteractiveViewer(
                    transformationController: _controller,
                    minScale: 1,
                    maxScale: 5,
                    child: SizedBox.expand(
                      child: AuthImage(
                          mediaId: widget.mediaId, groupId: widget.groupId, fit: BoxFit.contain),
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
        ],
      ),
    );
  }
}

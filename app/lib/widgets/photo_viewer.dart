import 'package:flutter/material.dart';

import 'auth_image.dart';

/// Full-screen, pinch-to-zoom viewer for a single media id (e.g. a profile photo).
/// Opened by tapping an avatar. Dismissed with the close button or the system back
/// gesture; double-tap toggles between fit-to-screen and a 2.5x zoom centred on the tap.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({super.key, required this.mediaId, this.groupId});

  final int mediaId;

  /// The connected group the media id belongs to (null = the current group), so the
  /// authenticated request and cache key resolve to the right server. See [AuthImage].
  final String? groupId;

  /// Pushes the viewer over everything (above the bottom nav) with a black backdrop.
  static Future<void> open(BuildContext context, {required int mediaId, String? groupId}) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => PhotoViewerScreen(mediaId: mediaId, groupId: groupId),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  final _controller = TransformationController();
  Offset? _doubleTapPos;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
              onDoubleTap: _handleDoubleTap,
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

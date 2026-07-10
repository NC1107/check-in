import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme/accent.dart';
import '../../theme/tokens.dart';

/// The size an [imgW]x[imgH] image takes when scaled to *cover* a [side]-square viewport:
/// the shorter dimension is pinned to [side] and the longer one overflows. Pure geometry so
/// it can be unit-tested without a rasterizer.
@visibleForTesting
Size coverSize(double imgW, double imgH, double side) {
  final ar = imgW / imgH;
  return ar >= 1 ? Size(side * ar, side) : Size(side, side / ar);
}

/// The translation that centres a [cover]-sized image in a [side]-square viewport (half the
/// overflow on each axis, as a negative offset). Pure geometry, unit-testable.
@visibleForTesting
Offset centerTranslate(Size cover, double side) =>
    Offset(-(cover.width - side) / 2, -(cover.height - side) / 2);

/// A circular pan-and-zoom cropper for profile photos. The picked image is shown covering
/// a square viewport with a circular guide; the user drags to position and pinches to zoom,
/// then "Use photo" rasterizes exactly what's framed to a square PNG. The app displays
/// profile photos clipped to a circle, so the inscribed circle of the square is what shows.
///
/// Bytes in, bytes out - no filesystem - so it works on every platform including web.
class PhotoCropScreen extends StatefulWidget {
  const PhotoCropScreen({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  /// Opens the cropper for [bytes]; resolves to the cropped square PNG bytes, or null if
  /// the user cancels.
  static Future<Uint8List?> crop(BuildContext context, Uint8List bytes) {
    return Navigator.of(context).push<Uint8List>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PhotoCropScreen(imageBytes: bytes),
    ));
  }

  @override
  State<PhotoCropScreen> createState() => _PhotoCropScreenState();
}

class _PhotoCropScreenState extends State<PhotoCropScreen> {
  final _boundaryKey = GlobalKey();
  final _tc = TransformationController();
  ui.Image? _image;
  double? _centeredForSide;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final img = await decodeImageFromList(widget.imageBytes);
    if (mounted) {
      setState(() => _image = img);
    } else {
      img.dispose();
    }
  }

  @override
  void dispose() {
    _tc.dispose();
    _image?.dispose();
    super.dispose();
  }

  /// Centre the cover image in the viewport once, when the layout size is first known.
  void _centerOnce(double side) {
    if (_image == null || _centeredForSide == side) return;
    _centeredForSide = side;
    final cover = coverSize(_image!.width.toDouble(), _image!.height.toDouble(), side);
    final t = centerTranslate(cover, side);
    _tc.value = Matrix4.identity()
      ..setEntry(0, 3, t.dx)
      ..setEntry(1, 3, t.dy);
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      final boundary = _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      // Rasterize the framed square to ~720px so profile photos stay crisp when zoomed
      // without shipping the full-resolution source.
      final pixelRatio = (720.0 / boundary.size.width).clamp(1.0, 4.0);
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted) return;
      Navigator.of(context).pop(data?.buffer.asUint8List());
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Move & Scale'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: LayoutBuilder(builder: (context, constraints) {
                  final side = constraints.biggest.shortestSide;
                  if (_image == null) {
                    return const CircularProgressIndicator(strokeWidth: 2);
                  }
                  if (_centeredForSide != side) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _centerOnce(side);
                    });
                  }
                  final cover = coverSize(
                      _image!.width.toDouble(), _image!.height.toDouble(), side);
                  return SizedBox(
                    width: side,
                    height: side,
                    child: Stack(
                      children: [
                        // Only this square (the framed image) is captured on confirm.
                        RepaintBoundary(
                          key: _boundaryKey,
                          child: ClipRect(
                            child: SizedBox(
                              width: side,
                              height: side,
                              child: InteractiveViewer(
                                constrained: false,
                                transformationController: _tc,
                                minScale: 1,
                                maxScale: 5,
                                child: SizedBox(
                                  width: cover.width,
                                  height: cover.height,
                                  child: RawImage(image: _image, fit: BoxFit.fill),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Circular guide, drawn on top and never captured.
                        IgnorePointer(
                          child: CustomPaint(
                            size: Size(side, side),
                            painter: _CircleGuidePainter(),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text('Drag to move  ·  pinch to zoom',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: kBorder),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _confirm,
                      style: FilledButton.styleFrom(
                        backgroundColor: context.accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Use photo'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dims everything outside a centred circle and draws a thin ring, so the user sees exactly
/// what a circular avatar will show.
class _CircleGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawPath(outside, Paint()..color = const Color(0x99000000));
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(covariant _CircleGuidePainter oldDelegate) => false;
}

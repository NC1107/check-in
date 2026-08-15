import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../api/models.dart';
import '../media/video_native.dart';
import '../state/app_state.dart';
import 'media_frame.dart';

/// Full-screen, pinch-to-zoom viewer for one or more attachments (e.g. a profile photo, or
/// all the media on a multi-image check-in). A clip plays inline (its poster shows until the
/// first frame is ready, then it autoplays looping). Opened by tapping an image. Swipe left/right
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
                    itemBuilder: (_, i) {
                      final m = widget.media[i];
                      // A clip plays here; a photo pinch-zooms. The video page owns exactly
                      // one controller and only while it is the visible page (active), so
                      // paging away tears it down - the strict lifecycle the plan calls for.
                      if (m.isVideo) {
                        return _VideoPage(media: m, groupId: widget.groupId, active: i == _page);
                      }
                      return _ZoomablePhoto(
                        media: m,
                        groupId: widget.groupId,
                        onZoomChanged: (z) {
                          if (i == _page) setState(() => _zoomed = z);
                        },
                      );
                    },
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

  // The tapped feed photo flies in via a shared [photoHeroTag]. Only the initial page needs
  // a matching source, but tagging every image page is harmless since each media id yields a
  // distinct tag; a clip's poster stays a plain fade.
  Widget _heroed(Widget child) => widget.media.isImage
      ? Hero(tag: photoHeroTag(widget.groupId, widget.media.id), child: child)
      : child;

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
          child: _heroed(
            MediaFrame(media: widget.media, groupId: widget.groupId, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

/// One clip inside the viewer's [PageView]: plays the stored MP4 (the main file, not the
/// poster variant) over its own poster, which stays visible until the first frame decodes so
/// there is no black flash. Tap toggles play/pause; a corner button mutes.
///
/// The lifecycle is the whole point. There is exactly one controller and only while this is
/// the active page: it is created when the page becomes active and torn down the moment it
/// stops being active (a swipe) or the viewer closes, and paused when the app backgrounds.
/// That keeps the app off the ListView-controller scar and inside Android's small pool of
/// hardware video decoders.
class _VideoPage extends ConsumerStatefulWidget {
  const _VideoPage({required this.media, required this.active, this.groupId});

  final PostMedia media;
  final String? groupId;
  final bool active;

  @override
  ConsumerState<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<_VideoPage> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.active) _create();
  }

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _create();
    } else if (!widget.active && old.active) {
      _teardown();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _teardown();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never let a clip keep playing (or holding its decoder) once the app is backgrounded.
    if (state == AppLifecycleState.paused) _controller?.pause();
  }

  void _create() {
    if (_controller != null) return;
    // Point at the clip itself (imageUrl with no variant), with the same bearer header the
    // image loader uses. Playback is device-only; on an unsupported host (a widget test)
    // initialize rejects and the poster simply stays put.
    final api = ref.read(contentApiProvider(widget.groupId));
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(api.imageUrl(widget.media.id)),
      httpHeaders: api.authHeaders,
    );
    _controller = controller;
    controller.initialize().then((_) {
      if (!mounted || _controller != controller) return;
      controller.setLooping(true);
      controller.setVolume(_muted ? 0 : 1);
      // Make the clip's audio follow the Ring/Silent switch (ambient category) rather than
      // playing through silent mode, which is video_player's forced default. Re-asserted here
      // because that default is set on the plugin's first init and never downgrades.
      unawaited(const VideoNative().respectSilentSwitch());
      if (widget.active) controller.play();
      setState(() => _initialized = true);
    }).catchError((_) {
      // No platform player (test/unsupported): keep showing the poster, no crash.
    });
  }

  void _teardown() {
    final controller = _controller;
    _controller = null;
    _initialized = false;
    controller?.pause();
    controller?.dispose();
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !_initialized) return;
    setState(() {
      controller.value.isPlaying ? controller.pause() : controller.play();
    });
  }

  void _toggleMute() {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _muted = !_muted;
      controller.setVolume(_muted ? 0 : 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final playing = _initialized && controller != null && controller.value.isPlaying;
    return GestureDetector(
      onTap: _togglePlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The poster (or a flat clip backdrop) under the video until the first frame lands.
          if (!_initialized)
            MediaFrame(media: widget.media, groupId: widget.groupId, fit: BoxFit.contain),
          if (_initialized && controller != null)
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
          // A play glyph while paused, so a paused clip does not read as a frozen photo.
          if (_initialized && !playing)
            const Center(
              child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 64),
            ),
          if (_initialized)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: IconButton(
                    icon: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        color: Colors.white, size: 26),
                    tooltip: _muted ? 'Unmute' : 'Mute',
                    onPressed: _toggleMute,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

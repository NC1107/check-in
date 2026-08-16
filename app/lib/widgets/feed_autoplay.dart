import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Builds the player for one feed clip. Behind a provider so a test can hand out a fake and
/// count what the feed asks for, rather than reaching for a real network player.
typedef FeedVideoFactory = VideoPlayerController Function(Uri url, Map<String, String> headers);

final feedVideoFactoryProvider = Provider<FeedVideoFactory>(
  // No mixWithOthers: an audible clip should take the audio focus the way Reels does, so it
  // pauses the user's music instead of talking over the top of it. Playing muted alongside
  // the music was the old behaviour and is now the user's choice, not the app's.
  (ref) => (url, headers) => VideoPlayerController.networkUrl(url, httpHeaders: headers),
);

/// Decides which feed clip - at most one, ever - may hold a video player.
///
/// Feed clips autoplay the way Reels does: the clip you are looking at plays and loops,
/// every other clip stays a poster. That has to be one controller for
/// the whole feed, not one per card: Android hands out a small pool of hardware video
/// decoders, and this codebase already has a scar from a feed list that built more per-item
/// state than it could carry. So the invariant lives here, in one object every tile has to
/// ask, instead of in each tile's own judgement.
///
/// Tiles report how much of themselves is on screen and the manager settles on a winner
/// after a short pause, so a fast scroll flies past a dozen clips without creating and
/// tearing down a player for each one. Nothing is decided inside a report: those arrive from
/// [VisibilityDetector] mid-frame, and a listener calling setState from there would be a
/// setState during build. Every decision comes out of a timer instead.
class FeedAutoplayController extends ChangeNotifier {
  FeedAutoplayController({this.settleDelay = const Duration(milliseconds: 200)});

  /// A clip has to be most of the way on screen to take the slot, and keeps it until it is
  /// most of the way off. The gap between the two thresholds is the point: with a single
  /// one, a clip resting near the line would hand the player back and forth every frame.
  static const double activateAbove = 0.6;
  static const double releaseBelow = 0.4;

  /// How long the feed has to hold still before the slot changes hands.
  final Duration settleDelay;

  final Map<Object, double> _visible = {};
  Object? _active;
  Timer? _settle;
  bool _enabled = true;

  /// The slot allowed to play right now, or null when nothing should be playing.
  Object? get activeSlot => _active;

  bool isActive(Object slot) => _active == slot;

  /// Whether the feed is the thing on screen at all. See [setEnabled].
  bool get enabled => _enabled;

  /// How much of [slot]'s tile is on screen, as a 0..1 fraction.
  void report(Object slot, double visibleFraction) {
    if (_visible[slot] == visibleFraction) return;
    _visible[slot] = visibleFraction;
    _schedule(settleDelay);
  }

  /// A tile is gone: scrolled out of the list, recycled, or the feed is being torn down. Its
  /// player goes with it, so the slot is free again immediately.
  void forget(Object slot) {
    _visible.remove(slot);
    if (_active == slot) _active = null;
    _schedule(Duration.zero);
  }

  /// Turns autoplay off while the feed is not what the user is looking at: another tab, or a
  /// route pushed over it (the full-screen viewer runs its own player, with sound). Off
  /// releases the active slot at once; on lets the last reported visibility pick a new one.
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _schedule(Duration.zero);
  }

  void _schedule(Duration delay) {
    _settle?.cancel();
    _settle = Timer(delay, _settleNow);
  }

  void _settleNow() {
    _settle = null;
    final next = _pick();
    if (next == _active) return;
    _active = next;
    notifyListeners();
  }

  Object? _pick() {
    if (!_enabled) return null;
    final current = _active;
    if (current != null && (_visible[current] ?? 0) >= releaseBelow) return current;
    Object? best;
    var bestFraction = 0.0;
    for (final entry in _visible.entries) {
      if (entry.value >= activateAbove && entry.value > bestFraction) {
        best = entry.key;
        bestFraction = entry.value;
      }
    }
    return best;
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }
}

/// Owns the one [FeedAutoplayController] a feed's clips share.
///
/// Sits above the feed so the manager - and with it every player - dies when the feed page
/// does. [enabled] should follow whether the feed is really on screen; the scope additionally
/// switches itself off whenever its route is no longer the top one, so a pushed post or the
/// full-screen viewer does not leave a clip decoding behind it.
class FeedAutoplayScope extends StatefulWidget {
  const FeedAutoplayScope({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  /// The feed's autoplay manager, or null outside a feed - where a clip is simply a poster.
  static FeedAutoplayController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FeedAutoplayHandle>()?.controller;

  @override
  State<FeedAutoplayScope> createState() => _FeedAutoplayScopeState();
}

class _FeedAutoplayScopeState extends State<FeedAutoplayScope> {
  final _controller = FeedAutoplayController();

  @override
  void initState() {
    super.initState();
    // The package's half-second default would leave a clip sitting still and silent for
    // long enough to read as broken. This is the interval visibility is batched over, not a
    // per-frame cost.
    VisibilityDetectorController.instance.updateInterval = const Duration(milliseconds: 100);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(FeedAutoplayScope old) {
    super.didUpdateWidget(old);
    _sync();
  }

  // ModalRoute.of registers a dependency on the route's status, so this re-runs when a route
  // is pushed over the feed or popped back off it.
  void _sync() {
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    _controller.setEnabled(widget.enabled && onTop);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _FeedAutoplayHandle(controller: _controller, child: widget.child);
}

class _FeedAutoplayHandle extends InheritedWidget {
  const _FeedAutoplayHandle({required this.controller, required super.child});

  final FeedAutoplayController controller;

  @override
  bool updateShouldNotify(_FeedAutoplayHandle old) => controller != old.controller;
}

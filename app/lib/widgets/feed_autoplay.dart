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

/// The tile that currently holds the feed's one player, seen from the manager.
///
/// Implemented by the feed clip's state. The manager holds at most one of these at a time,
/// and only between the tile's player coming up and it going away again.
abstract interface class FeedClipPlayer {
  /// How far into the clip the player has got.
  Duration get position;

  /// Hands the live controller over, leaving the tile on its poster. The tile keeps neither
  /// a claim to drive it nor the job of disposing it until it comes back. Null when the
  /// player has already gone.
  VideoPlayerController? detach();

  /// Takes a lent controller back. False when this tile can no longer use it - it has left
  /// the list, or been recycled onto another clip - in which case the manager disposes it.
  bool reattach(VideoPlayerController controller);
}

/// A feed tile's live player, on loan to the full-screen viewer.
///
/// Lending the running controller rather than building a second one for the same clip is
/// the point: a second controller means a fresh network init and a seek, which the user
/// sees as a play glyph and a stall at exactly the moment they expected the clip to carry
/// on. The feed-wide "one player" invariant survives because the player moved, not
/// multiplied.
class LentClip {
  const LentClip({required this.mediaId, required this.controller, required this.release});

  final int mediaId;

  /// Initialised, playing, at the position the feed had reached, at the shared volume.
  final VideoPlayerController controller;

  /// Gives the player back once the viewer is done with it: the feed re-attaches it to the
  /// tile it came from, or disposes it if that tile has gone.
  final void Function(int mediaId, VideoPlayerController controller) release;
}

/// Decides which feed clip - at most one, ever - may hold a video player.
///
/// Feed clips autoplay the way Reels does: the clip you are looking at plays and loops,
/// every other clip stays a poster. That has to be one controller for the whole feed, not
/// one per card: Android hands out a small pool of hardware video decoders, and this
/// codebase already has a scar from a feed list that built more per-item state than it could
/// carry. So the invariant lives here, in one object every tile has to ask, instead of in
/// each tile's own judgement.
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

  // The tile holding the player, reached through an interface rather than copied values,
  // because playback moves on between the tile offering itself and a tap reading it. One
  // record rather than a map, because there is only ever one player.
  ({Object slot, int mediaId, String? groupId, FeedClipPlayer player})? _playing;

  // The player that left for the full-screen viewer. Kept apart from _playing because no
  // tile is driving it: it must survive the tile releasing its slot (a route over the feed
  // does exactly that) and it must come back here to be disposed.
  ({Object slot, int mediaId, VideoPlayerController controller, FeedClipPlayer player})? _lent;

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
  ///
  /// A lent player is deliberately not touched here. It belongs to the viewer until it is
  /// released, and that release is what decides between re-attaching and disposing it.
  void forget(Object slot) {
    _visible.remove(slot);
    if (_active == slot) _active = null;
    unpublish(slot);
    _schedule(Duration.zero);
  }

  /// Offers [slot]'s live player for as long as it holds one, so a tap can open the
  /// full-screen viewer on the clip as the feed already has it - the position it reached,
  /// and the running player itself.
  void publish(
    Object slot, {
    required int mediaId,
    required FeedClipPlayer player,
    String? groupId,
  }) {
    _playing = (slot: slot, mediaId: mediaId, groupId: groupId, player: player);
  }

  /// [slot]'s player is gone, and its position with it.
  void unpublish(Object slot) {
    if (_playing?.slot == slot) _playing = null;
  }

  /// Whether a player is out with the full-screen viewer. It is still the feed's one player;
  /// it is simply somewhere else, which is why no tile may build another for it.
  bool get isLending => _lent != null;

  /// How far into [mediaId] the feed is right now, or null when that is not the clip
  /// playing. Scoped by group as well: a cross-post puts one media id under two groups, and
  /// only the tile the user is actually watching knows a position.
  Duration? positionOf({required int mediaId, String? groupId}) {
    final playing = _playing;
    if (playing == null || playing.mediaId != mediaId || playing.groupId != groupId) return null;
    return playing.player.position;
  }

  /// Hands the running player for [mediaId] to the full-screen viewer, or null when this
  /// feed has no live player for that clip (a poster, another tile's clip, a photo).
  ///
  /// The tile drops back to its poster and stops being the player's owner; nothing is
  /// created and nothing is disposed, so what the viewer shows is the frame the feed was on.
  LentClip? lend({required int mediaId, String? groupId}) {
    final playing = _playing;
    if (playing == null || playing.mediaId != mediaId || playing.groupId != groupId) return null;
    final controller = playing.player.detach();
    if (controller == null) return null;
    _playing = null;
    _lent = (
      slot: playing.slot,
      mediaId: mediaId,
      controller: controller,
      player: playing.player,
    );
    return LentClip(mediaId: mediaId, controller: controller, release: reclaim);
  }

  /// Takes a lent player back from the viewer. The media id comes along because it is what
  /// the viewer knows the player by; which player came back is settled by identity here.
  ///
  /// Deferred a frame because the viewer releases from its dispose, which runs inside the
  /// frame's build: re-attaching marks the feed tile dirty, and that is not allowed from
  /// there. The tile is still showing the poster this player left it on, so the wait costs
  /// a still frame rather than a gap.
  void reclaim(int mediaId, VideoPlayerController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore(controller));
  }

  void _restore(VideoPlayerController controller) {
    final lent = _lent;
    if (lent != null && identical(lent.controller, controller)) {
      _lent = null;
      if (lent.player.reattach(controller)) return;
    }
    // Nobody left to take it: the tile scrolled away, was recycled onto another clip, or the
    // whole feed went. Ownership is back here, so this is the last chance to hand the
    // decoder back rather than leak it.
    unawaited(controller.pause());
    unawaited(controller.dispose());
  }

  /// Turns autoplay off while the feed is not what the user is looking at: another tab, or a
  /// route pushed over it (the full-screen viewer takes playback on, usually with this very
  /// player). Off releases the active slot at once; on lets the last reported visibility
  /// pick a new one.
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

  // A lent player is not disposed here: the viewer is still drawing it. The release it
  // already holds runs through _restore, finds no tile left, and disposes it there.
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

  /// What the full-screen viewer needs to carry a feed clip's playback across: where
  /// [mediaId] has got to, if it is the clip playing right now, and nothing at all
  /// otherwise (a poster, another tile's clip, or no feed above this at all).
  ///
  /// Read without subscribing, because this answers a tap rather than a build.
  static Map<int, Duration> continuation(
    BuildContext context, {
    required int mediaId,
    String? groupId,
  }) {
    final handle = context.getElementForInheritedWidgetOfExactType<_FeedAutoplayHandle>()?.widget
        as _FeedAutoplayHandle?;
    final at = handle?.controller.positionOf(mediaId: mediaId, groupId: groupId);
    return at == null || at == Duration.zero ? const {} : {mediaId: at};
  }

  /// Hands the live player for [mediaId] to the full-screen viewer, or null when the feed
  /// has none for it - which is also what happens outside a feed, where the viewer builds
  /// its own player as it always has.
  ///
  /// Read without subscribing, because this answers a tap rather than a build.
  static LentClip? lend(BuildContext context, {required int mediaId, String? groupId}) {
    final handle = context.getElementForInheritedWidgetOfExactType<_FeedAutoplayHandle>()?.widget
        as _FeedAutoplayHandle?;
    return handle?.controller.lend(mediaId: mediaId, groupId: groupId);
  }

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

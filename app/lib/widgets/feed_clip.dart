import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../api/models.dart';
import '../media/video_native.dart';
import '../state/app_state.dart';
import 'clip_poster.dart';
import 'feed_autoplay.dart';

/// One clip in the feed: its poster until [FeedAutoplayController] hands this tile the
/// single autoplay slot, then the clip itself - looping, with sound - drawn over that same
/// poster.
///
/// The tile only ever asks; the manager decides, which is what keeps the whole feed to one
/// player. Tapping the clip does not end that player: the tile lends it to the full-screen
/// viewer (see [FeedClipPlayer]) and drops back to its poster, so full screen picks up the
/// exact frame the feed was on instead of paying for a second player's init and seek. It
/// comes back when the viewer closes.
///
/// Everything else here is about failing quietly: the poster is never removed from
/// under the video, so there is no black gap while the first frame decodes, and a clip that
/// will not initialise (offline, an odd codec, a host with no player at all) leaves the
/// poster exactly as it was. Autoplay is decoration - it must never turn a check-in into an
/// error card.
///
/// Sound follows the phone: the ambient audio session means a clip is audible with the
/// ringer on and silent with the switch flipped, no ringer detection in Dart. On top of that
/// the speaker badge is a real toggle backed by [clipsMutedProvider], so a mute here is the
/// same mute the full-screen viewer and every later clip start from. A data-saver setting
/// ("autoplay on wifi only") would hang off the manager rather than here; there is no such
/// setting yet and clips are capped at ten seconds.
class FeedClip extends ConsumerStatefulWidget {
  const FeedClip({
    super.key,
    required this.media,
    required this.autoplay,
    this.groupId,
    this.fit = BoxFit.cover,
    this.onImageResolved,
  });

  final PostMedia media;
  final FeedAutoplayController autoplay;

  /// The connected group the media belongs to (null = the current group).
  final String? groupId;
  final BoxFit fit;
  final ValueChanged<ImageInfo>? onImageResolved;

  @override
  ConsumerState<FeedClip> createState() => _FeedClipState();
}

class _FeedClipState extends ConsumerState<FeedClip>
    with WidgetsBindingObserver
    implements FeedClipPlayer {
  // One key, two jobs: VisibilityDetector needs a unique one, and the manager needs a handle
  // for this tile. Per tile rather than per clip, so the same clip on screen twice (a
  // cross-post seen from two groups) is two slots competing, not one entry they share.
  final Key _slot = UniqueKey();

  VideoPlayerController? _controller;
  bool _firstFrame = false;

  // The player this tile lent to the full-screen viewer. Not ours while it is out: not to
  // drive, not to dispose, and above all not to build a second one alongside.
  VideoPlayerController? _lentOut;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.autoplay.addListener(_onSlotChanged);
  }

  @override
  void didUpdateWidget(FeedClip old) {
    super.didUpdateWidget(old);
    if (old.autoplay != widget.autoplay) {
      old.autoplay.removeListener(_onSlotChanged);
      old.autoplay.forget(_slot);
      widget.autoplay.addListener(_onSlotChanged);
    }
    // A recycled tile now points at a different clip: the player it holds is for the old one.
    if (old.media.id != widget.media.id || old.groupId != widget.groupId) {
      _lentOut = null; // whatever is out belongs to a clip this tile no longer shows
      _teardown();
      _onSlotChanged();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.autoplay.removeListener(_onSlotChanged);
    widget.autoplay.forget(_slot);
    // Dropping the claim, not the player: the viewer still has it, and releasing it there is
    // what disposes it.
    _lentOut = null;
    _teardown();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A backgrounded app keeps neither the playback nor the decoder busy.
    if (state == AppLifecycleState.paused) {
      _controller?.pause();
    } else if (state == AppLifecycleState.resumed && widget.autoplay.isActive(_slot)) {
      _controller?.play();
    }
  }

  void _onSlotChanged() {
    final active = widget.autoplay.isActive(_slot);
    final controller = _controller;
    // A tile whose player is out with the viewer waits for it rather than building a second
    // one: that would be two decoders for one clip, and the wrong one would be on screen
    // when the viewer closes.
    if (active && controller == null && _lentOut == null) {
      _create();
    } else if (active && controller != null && _firstFrame && !controller.value.isPlaying) {
      // Taken back from the viewer before the feed had settled on a slot again.
      controller.play();
    } else if (!active && controller != null) {
      _teardown();
      if (mounted) setState(() {});
    }
  }

  void _create() {
    // The clip itself (imageUrl with no variant), with the same bearer header the image
    // loader sends - the poster and the clip come from the same authenticated endpoint.
    final api = ref.read(contentApiProvider(widget.groupId));
    final controller = ref.read(feedVideoFactoryProvider)(
      Uri.parse(api.imageUrl(widget.media.id)),
      api.authHeaders,
    );
    _controller = controller;
    controller.initialize().then((_) {
      if (!mounted || _controller != controller) return;
      controller.setLooping(true);
      controller.setVolume(ref.read(clipsMutedProvider) ? 0 : 1);
      // Make that volume follow the Ring/Silent switch (ambient category) rather than play
      // through silent mode, which is video_player's forced default. Re-asserted here
      // because that default is set on the plugin's first init and never downgrades.
      unawaited(const VideoNative().respectSilentSwitch());
      // Offer the running player, so tapping the card opens the viewer on the clip as it is
      // here rather than starting a second one over.
      widget.autoplay.publish(
        _slot,
        mediaId: widget.media.id,
        groupId: widget.groupId,
        player: this,
      );
      if (widget.autoplay.isActive(_slot)) controller.play();
      setState(() => _firstFrame = true);
    }).catchError((_) {
      // Nothing to show the user: the poster is already what they are looking at.
    });
  }

  @override
  Duration get position => _controller?.value.position ?? Duration.zero;

  @override
  VideoPlayerController? detach() {
    final controller = _controller;
    if (controller == null) return null;
    _controller = null;
    _firstFrame = false;
    _lentOut = controller;
    widget.autoplay.unpublish(_slot);
    // Back to the poster, which is the same still the video was drawn over: nothing moves
    // as the viewer takes the picture on.
    setState(() {});
    return controller;
  }

  @override
  bool reattach(VideoPlayerController controller) {
    if (!mounted || !identical(_lentOut, controller)) return false;
    _lentOut = null;
    _controller = controller;
    _firstFrame = true;
    controller.setVolume(ref.read(clipsMutedProvider) ? 0 : 1);
    widget.autoplay.publish(
      _slot,
      mediaId: widget.media.id,
      groupId: widget.groupId,
      player: this,
    );
    // The feed may well have moved on underneath the viewer, in which case this tile is
    // holding a player it is no longer allowed to run.
    widget.autoplay.isActive(_slot) ? controller.play() : controller.pause();
    setState(() {});
    return true;
  }

  void _teardown() {
    final controller = _controller;
    _controller = null;
    _firstFrame = false;
    widget.autoplay.unpublish(_slot);
    controller?.pause();
    controller?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final playing = _firstFrame && controller != null;
    final muted = ref.watch(clipsMutedProvider);
    // The choice is shared, so it can change while this clip is the one playing - muted in
    // the viewer, or by the stored value arriving after playback started.
    ref.listen(clipsMutedProvider, (_, next) => _controller?.setVolume(next ? 0 : 1));
    return VisibilityDetector(
      key: _slot,
      onVisibilityChanged: (info) {
        if (mounted) widget.autoplay.report(_slot, info.visibleFraction);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipPoster(
            media: widget.media,
            groupId: widget.groupId,
            fit: widget.fit,
            onImageResolved: widget.onImageResolved,
            showOverlays: !playing,
          ),
          if (playing) _video(controller),
          // Sound is on by default, so the badge has to be able to turn it off where the
          // user meets it. Its own tap beats the card's, which still opens the clip
          // full-screen.
          if (playing)
            Positioned(
              right: 0,
              bottom: 0,
              child: _MuteButton(
                muted: muted,
                onTap: () => ref.read(clipsMutedProvider.notifier).toggle(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _video(VideoPlayerController controller) {
    final size = controller.value.size;
    if (size.isEmpty) return const SizedBox.shrink();
    // Fill the box the poster already sized, so the picture lands exactly where the still
    // was instead of jumping to its own letterboxed shape as it starts.
    return ClipRect(
      child: FittedBox(
        fit: widget.fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

/// The speaker badge over a playing clip. The circle stays the small corner mark it always
/// was; the padding around it is what makes the target big enough to hit with a thumb
/// without the badge itself growing or moving.
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: muted ? 'Unmute' : 'Mute',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(
              muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              color: Colors.white,
              size: 15,
            ),
          ),
        ),
      ),
    );
  }
}

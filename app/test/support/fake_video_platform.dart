import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Stands in for the platform video player. A widget test has none, so without this every
/// clip would fall into the poster fallback and the interesting half of playback - autoplay
/// picking one tile, the viewer seeking to where the feed had got to - could not be
/// asserted at all.
///
/// Shared by the feed and viewer tests so both are held to the same stand-in.
class FakeVideoPlatform extends VideoPlayerPlatform {
  final List<int> disposed = [];

  /// URL fragments this platform refuses to open, for the failure path.
  final Set<String> refuse = {};

  /// Every data source the platform was asked to open, in order - attempts included. A
  /// player handed from the feed to the full-screen viewer must not add an entry: building
  /// a second one for the same clip is the stall this hand-off exists to remove.
  final List<String> created = [];

  /// What the player was told to do, in order: `'seek:0:00:02.000000'`, `'play'`,
  /// `'volume:0.0'`. Order is the point for seek-then-play, so it is one log rather than
  /// three lists.
  final List<String> calls = [];

  /// What [getPosition] reports, which is what a playing controller polls itself up to.
  Duration position = Duration.zero;

  final Map<int, StreamController<VideoEvent>> _events = {};
  int _nextId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final uri = options.dataSource.uri ?? '';
    created.add(uri);
    if (refuse.any(uri.contains)) {
      throw PlatformException(code: 'VideoError', message: 'no player for $uri');
    }
    final id = ++_nextId;
    // Closed in dispose(playerId) below. close_sinks cannot see that: the controller is
    // handed straight to a map rather than kept in a field it can follow.
    // ignore: close_sinks
    final events = StreamController<VideoEvent>.broadcast();
    // Announce readiness only once someone is listening: a broadcast stream drops whatever
    // was sent before that, and the controller subscribes after create returns.
    events.onListen = () => scheduleMicrotask(() {
          if (events.isClosed) return;
          events.add(VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 6),
            size: const Size(720, 1280),
          ));
        });
    _events[id] = events;
    return id;
  }

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await _events.remove(playerId)?.close();
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _events[playerId]?.stream ?? const Stream<VideoEvent>.empty();

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> setVolume(int playerId, double volume) async => calls.add('volume:$volume');

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    this.position = position;
    calls.add('seek:$position');
  }

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox.expand();
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:image_picker/image_picker.dart';
import 'package:native_exif/native_exif.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../media/video_native.dart';
import '../../notifications/birthday_notifier.dart';
import '../../notifications/push_messaging.dart';
import '../../state/app_state.dart';
import '../../state/taggable_people.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/feed_autoplay.dart';
import '../../widgets/gif_picker.dart';
import '../../widgets/user_avatar.dart';
import '../memories/memories_screen.dart';
import '../post/post_detail_screen.dart';
import '../profile/profile_screen.dart';
import '../whats_new/release_notes.dart';
import 'compose_media_buttons.dart';
import 'feed_screen.dart';

/// Whether a picked file has to be re-encoded before upload. Photos do: it transcodes the
/// iPhone HEIC the server cannot read and downscales, so the server never decodes a
/// full-resolution image. An animated gif must not be - the compressor writes back a
/// single flattened jpeg frame, which is how every gif posted to date lost its animation
/// before it ever reached the server.
bool needsReencodeBeforeUpload(String path) => fileExtension(path) != 'gif';

/// Whether a picked file is a clip. The gallery picker can hand one back even when asked
/// for images, and it takes the video pipeline (trim/encode/poster) rather than the photo
/// one. Checking the extension here is cheaper than per-platform picker filtering and
/// behaves the same everywhere.
bool isVideoPick(String path) =>
    const {'mp4', 'mov', 'm4v', '3gp', 'avi', 'webm', 'mkv'}.contains(fileExtension(path));

/// The longest clip that can be posted without trimming. The server caps clips too (a hair
/// higher, for encoder slop); this is the user-facing window the trim sheet enforces.
const kMaxClipMs = 10000;

/// The shortest clip the trim sheet will hand back. A handle dragged closer than this is held
/// here rather than allowed to collapse the window to nothing.
const kMinClipMs = 1000;

/// Which handle the user is dragging. When a span constraint is hit the clamp resolves it by
/// moving the dragged edge, never the opposite one, so a handle can never drag its partner
/// along with it.
enum TrimEdge { start, end }

/// Which upload path a picked file takes. A clip is encoded and gets a poster; an animated
/// gif is uploaded raw so it keeps moving; everything else is a photo re-encoded to jpeg.
/// One selector so no call site can disagree about what a given file is.
enum UploadKind { video, rawImage, reencodeImage }

UploadKind uploadKindFor(String path) {
  if (isVideoPick(path)) return UploadKind.video;
  return needsReencodeBeforeUpload(path) ? UploadKind.reencodeImage : UploadKind.rawImage;
}

/// Whether a clip picked at [durationMs] is over the cap and must be trimmed first.
bool clipNeedsTrim(int durationMs) => durationMs > kMaxClipMs;

/// Clamps an explicit (start, end) selection to a legal trim window: both edges inside
/// [0, duration], the span between them at least [minMs] and at most [maxMs]. [moved] names
/// the handle the user just dragged, so a violated span is fixed by moving that edge and the
/// opposite (anchor) edge is left where it is. Dropping the [maxMs] cap is exactly what would
/// let a clip longer than the limit through.
({int startMs, int endMs}) clampTrimWindow(
  int startMs,
  int endMs,
  int durationMs, {
  int maxMs = kMaxClipMs,
  int minMs = kMinClipMs,
  TrimEdge moved = TrimEdge.end,
}) {
  final duration = durationMs < 0 ? 0 : durationMs;
  // A clip shorter than the minimum span can only ever give back its whole self.
  if (duration <= minMs) return (startMs: 0, endMs: duration);
  if (moved == TrimEdge.start) {
    // The end is the anchor; move the start to satisfy the span against it.
    final end = endMs.clamp(minMs, duration);
    final start = startMs.clamp((end - maxMs).clamp(0, duration), end - minMs);
    return (startMs: start, endMs: end);
  }
  // The start is the anchor; move the end.
  final start = startMs.clamp(0, duration - minMs);
  final end = endMs.clamp(start + minMs, (start + maxMs).clamp(0, duration));
  return (startMs: start, endMs: end);
}

/// Slides a chosen trim window along the clip by [deltaMs], the way dragging the region
/// between the two handles does: start and end move together and the span between them is
/// preserved exactly. The window is stopped at the ends of the clip rather than squeezed, so
/// a drag that runs off either edge keeps the length the user picked. A shift that changed
/// the span would silently re-trim a window that was already settled.
({int startMs, int endMs}) shiftTrimWindow(int startMs, int endMs, int deltaMs, int durationMs) {
  final duration = durationMs < 0 ? 0 : durationMs;
  final span = (endMs - startMs).clamp(0, duration);
  final start = (startMs + deltaMs).clamp(0, duration - span);
  return (startMs: start, endMs: start + span);
}

/// Whether a group's server accepts video, so compose can offer a clip only where it would
/// be stored rather than uploading into a rejection. A server predating typed media reports
/// images-only (see [ServerInfo.mediaTypes]).
bool mediaTypesSupportsVideo(List<String> mediaTypes) => mediaTypes.contains('video');

/// Whether compose may offer the clip option for the current selection: at least one target
/// group is chosen and every one of them can store video. A clip is a single attachment
/// shared to all targets, so one non-video group in the selection takes the option away.
bool clipComposeAllowed(Iterable<ServerAccount> selectedTargets) {
  final list = selectedTargets.toList();
  return list.isNotEmpty && list.every((g) => mediaTypesSupportsVideo(g.mediaTypes));
}

/// Whether compose may offer the gif picker: [active] (the group whose proxy answers the
/// search) has to be signed in and able to search gifs, and every cross-post target has to
/// be able to actually store one. Search only ever goes through one group's server - Klipy's
/// results don't depend on whose key asked - but the attachment is uploaded to every target,
/// so mediaTypes support is checked against all of them, the same way clipComposeAllowed
/// checks video support.
bool gifComposeAllowed(ServerAccount? active, Iterable<ServerAccount> selectedTargets) {
  final list = selectedTargets.toList();
  return active != null &&
      active.gifSearch &&
      list.isNotEmpty &&
      list.every((g) => g.mediaTypes.contains('gif'));
}

/// The native trim/location seam, overridable in tests with a fake so the clip flow can be
/// exercised without a device.
final videoNativeProvider = Provider<VideoNative>((ref) => const VideoNative());

/// Runs a clip's poster upload, swallowing any failure. A poster is only the pre-play still;
/// the feed renders and plays a posterless clip fine, so attaching it must never be able to
/// fail the post it belongs to.
Future<void> attachPosterBestEffort(Future<void> Function() attach) async {
  try {
    await attach();
  } catch (_) {
    // Intentionally ignored: the clip still posts and plays without a stored poster.
  }
}

/// A short opaque id (16 random bytes, hex) that links a post's copies across groups. The
/// servers never coordinate, so the client mints it; collisions are astronomically unlikely.
String _newCrossPostId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

const _bgMain = kBgMain;
const _bgSurface = kBgSurface;
const _bgSurfaceHover = kBgSurfaceHover;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;

/// HomeShell hosts the main tabs once a user is logged in.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with SingleTickerProviderStateMixin {
  int _index = 0;

  // Drives the hidden Memories surface: 0 = closed, 1 = fully open, tracked live by the
  // handle's drag and the surface's own dismiss drag (see MemoriesDragDriver). The Android
  // back interception lives on MemoriesSurface itself, not here - see its doc comment.
  late final _memoriesController =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: 0);

  // Mirrors "the surface is anywhere above fully closed" as plain state, so it can gate
  // FeedAutoplayScope.enabled below. The surface is a Stack sibling of the feed, not a
  // pushed route - FeedAutoplayScope's own isCurrent check never fires for it - so without
  // this a feed clip keeps playing, audibly, behind the opaque panel the instant the drag (or
  // the open animation) starts moving off 0, not just once it settles fully open.
  bool _memoriesOpen = false;

  void _onMemoriesValueChanged() {
    final open = _memoriesController.value > 0;
    if (open != _memoriesOpen) setState(() => _memoriesOpen = open);
  }

  /// Settles the surface shut - the header's close button and Android back (both routed
  /// through MemoriesSurface's onClose) share this rather than duplicating the
  /// reduced-motion duration choice.
  void _closeMemories() {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    _memoriesController.animateTo(0,
        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOut);
  }

  @override
  void initState() {
    super.initState();
    _memoriesController.addListener(_onMemoriesValueChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _registerServices();
      // Route notification taps: switch to the push's origin group and open the post.
      setPushTapHandler(_onPushTap);
      // Show "What's New" once after an update (silent on a fresh install).
      maybeShowWhatsNew(context);
    });
  }

  @override
  void dispose() {
    _memoriesController.removeListener(_onMemoriesValueChanged);
    _memoriesController.dispose();
    super.dispose();
  }

  /// (Re-)registers this device with EVERY signed-in group: push token on each server
  /// and birthday reminders across all of them. Idempotent - the server upserts device
  /// tokens - so it's safe to re-run whenever the set of groups changes.
  void _registerServices() {
    final session = ref.read(multiSessionProvider);
    if (session.signedIn.isEmpty) return;
    scheduleBirthdayNotifications([
      for (final g in session.signedIn)
        (api: ref.read(apiForGroupProvider(g.id)), id: g.id, name: g.displayName)
    ]);
    requestDeviceToken([for (final g in session.signedIn) ref.read(apiForGroupProvider(g.id))]);
    _refreshDigestOffset(session);
  }

  /// Tells every group where this member currently is, so the daily summary keeps landing
  /// at the hour they picked. Without this a DST change (or a flight) would silently shift
  /// their 8pm digest by an hour. Best-effort: an unreachable group keeps its old offset
  /// and re-syncs on the next launch.
  void _refreshDigestOffset(MultiSession session) {
    final offset = DateTime.now().timeZoneOffset.inMinutes;
    for (final g in session.signedIn) {
      final api = ref.read(apiForGroupProvider(g.id));
      unawaited(() async {
        try {
          await api.updateNotificationPrefs(digestOffset: offset);
        } catch (_) {
          // Nothing to do: the digest still fires, just against the previous offset.
        }
      }());
    }
  }

  /// A push payload carries the origin server's public URL (see the Go side's
  /// pushData); match it to a connected group, make that group active, and open the
  /// post there - post ids are only unique per server.
  void _onPushTap(Map<String, dynamic> data) {
    final postId = int.tryParse('${data['postId']}');
    if (postId == null) return;
    final session = ref.read(multiSessionProvider);
    final server = data['server'] as String?;
    ServerAccount? target;
    if (server != null && server.isNotEmpty) {
      target = session.byId(MultiSessionController.groupIdFor(server));
    }
    final t = target ?? session.current;
    if (t == null || !t.isSignedIn || !mounted) return;
    // Make sure the tapped group is visible in the feed when you return to it.
    ref.read(multiSessionProvider.notifier).showGroup(t.id);
    // A comment or reply notification should land on the thread, not the top of the post.
    final focusComments = data['type'] == 'comment' || data['type'] == 'reply';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PostDetailScreen(postId: postId, groupId: t.id, focusComments: focusComments),
      ),
    );
  }

  void _showCompose() {
    showModalBottomSheet<bool?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => const ComposeSheet(),
    ).then((posted) {
      if (posted == true) {
        ref.invalidate(feedProvider); // surface the new post immediately
        // Nudge the always-alive profile tab to reload so the new post shows there too.
        ref.read(profileRefreshProvider.notifier).bump();
        if (_index != 0) setState(() => _index = 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Re-register device/push/birthdays when a group is added, removed, or re-signed-in.
    ref.listen<String>(
      multiSessionProvider.select((s) => [for (final g in s.signedIn) g.id].join(',')),
      (prev, next) {
        if (prev != next) _registerServices();
      },
    );
    // The authoritative fix for a capability drop mid-drag (a shown-group change, or a
    // capability update landing while a finger is down on the handle): force the surface
    // shut whenever nothing capable is shown anymore and it isn't already closed, no matter
    // which widget's build/dispose runs when. This owns the controller, so it holds
    // regardless - MemoriesHandle also settles a drag of its own as a second line of
    // defense (see its dispose() and build()'s incapable branch), but this is what must
    // never miss: an open (or mid-transition) surface for a capability that just
    // disappeared has nothing left to show and no reachable close button on some layouts.
    ref.listen<bool>(
      multiSessionProvider.select((s) => s.memoriesCapableShownGroups.isNotEmpty),
      (prev, next) {
        if (!next && _memoriesController.value != 0) _closeMemories();
      },
    );
    final account = ref.watch(currentAccountProvider);
    final me = account?.user;

    // Admin/member management is reached from the profile (host badge + Members button),
    // so it isn't a bottom-nav destination.
    final pages = <Widget>[
      // Clips in the feed autoplay, and this scope is what holds the whole feed to a single
      // player. It also has to be told when the feed is not the visible tab: an IndexedStack
      // keeps the other page alive but stops painting it, so nothing inside the page would
      // ever learn it went off screen. The Memories surface is the same story: it is a Stack
      // sibling drawn over the feed, not a pushed route, so FeedAutoplayScope's own
      // ModalRoute.isCurrent check never notices it - _memoriesOpen is what does, the instant
      // the surface starts opening rather than only once it has fully covered the feed.
      FeedAutoplayScope(enabled: _index == 0 && !_memoriesOpen, child: const FeedScreen()),
      // One profile for the one human: merged across every signed-in group.
      if (me != null) const MyProfileScreen(),
    ];

    return Scaffold(
      backgroundColor: _bgMain,
      body: Stack(
        children: [
          IndexedStack(index: _index, children: pages),
          Positioned.fill(
            child: MemoriesSurface(controller: _memoriesController, onClose: _closeMemories),
          ),
        ],
      ),
      // Faded (and, for the FAB, slid down a little) out together with the same controller
      // that opens the Memories surface, so the two motions read as one rather than a panel
      // sliding in over chrome that's still sitting there - the founder's own ask: "we don't
      // need the bottom bar in the memories page as we can just swipe out of it". See
      // _ChromeFade's own doc comment for why this is driven off _memoriesController
      // directly rather than a second animation of its own.
      floatingActionButton: _ChromeFade(
        key: const Key('fabChrome'),
        controller: _memoriesController,
        slideDy: 24,
        child: SizedBox(
          height: 58,
          width: 58,
          child: FloatingActionButton(
            onPressed: _showCompose,
            backgroundColor: context.accent,
            foregroundColor: context.onAccent,
            elevation: 4,
            tooltip: 'New check-in',
            shape: const CircleBorder(),
            child: const Icon(Icons.add, size: 28),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: _ChromeFade(
        key: const Key('bottomBarChrome'),
        controller: _memoriesController,
        slideDy: 24,
        // A Stack, not just the BottomAppBar: the handle is overlaid on top of the bar's
        // leading edge rather than laid out as one of its Row children. Making it a Row child
        // (even a fixed-width one, mirrored by a matching spacer on the other end to keep the
        // FAB notch centered) still measurably shifted the Feed/You icons inward by half the
        // handle's width - the notch stayed centered, but the tabs visibly moved, which is a
        // regression from a feature that is supposed to be invisible. An overlay takes no
        // layout space at all, so the Row below is exactly what it was before this feature.
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            BottomAppBar(
              color: _bgMain,
              elevation: 0,
              height: 64,
              padding: EdgeInsets.zero,
              shape: const CircularNotchedRectangle(),
              notchMargin: 9,
              child: DecoratedBox(
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: _border))),
                child: Row(
                  children: [
                    _NavItem(
                      icon: Icons.home_outlined,
                      activeIcon: Icons.home_rounded,
                      label: 'Feed',
                      selected: _index == 0,
                      // Re-tapping Feed while already on it scrolls the feed back to the top.
                      onTap: () => _index == 0
                          ? ref.read(feedScrollToTopProvider.notifier).bump()
                          : setState(() => _index = 0),
                    ),
                    const SizedBox(width: 64), // FAB notch
                    _NavItem(
                      icon: Icons.person_outline,
                      activeIcon: Icons.person_rounded,
                      label: 'You',
                      selected: _index == 1,
                      onTap: me != null ? () => setState(() => _index = 1) : null,
                    ),
                  ],
                ),
              ),
            ),
            // The hidden Memories entry point: a small grab handle overlaid on the bar, not a
            // fourth Row destination - see MemoriesHandle's doc comment. Positioned to fill the
            // Stack's full height (top:0, bottom:0) rather than a fixed 64-tall box centered by
            // the Stack's own `alignment: centerLeft` above: BottomAppBar wraps its content in
            // a SafeArea *outside* a fixed-height 64 box (see Flutter's BottomAppBar.build), so
            // the bar's real rendered height is 64 plus the device's bottom safe inset, with
            // the Feed/You row pinned to the TOP of that box rather than centered within it. A
            // handle sized to a flat 64 and centered by the Stack's alignment centers against
            // that taller total height instead, which lands it visibly below the icons' actual
            // center on any device with a bottom safe inset (the founder's own bug report).
            // Matching the full height here and repeating BottomAppBar's exact
            // SafeArea-then-64-box shape inside MemoriesHandle itself (see its build()) is what
            // makes the two align pixel-for-pixel regardless of that inset.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: kMemoriesHandleWidth,
              child: MemoriesHandle(controller: _memoriesController, feedActive: _index == 0),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fades (and optionally slides) [child] out as [controller] goes 0 (closed) to 1 (fully
/// open) - the bottom bar and the FAB's own exit, driven by the exact same
/// [AnimationController] the Memories surface itself opens and closes with, rather than a
/// second animation of their own that could ever drift out of sync with it. Deliberately not
/// a controller [child] merely watches passively, either: because [child]'s visibility is a
/// pure function of the SAME single value the surface's own openness is, there is no state
/// this can independently land in where the bar is hidden while the surface reads closed (or
/// vice versa) - the two can never disagree, since they are quite literally the same number.
///
/// Also stops [child] from being hit-tested once the surface is drawing over the screen at
/// all (anywhere above fully closed, not only once fully open) - a tap landing on a nav item
/// or the FAB while the surface is mid-transition over it would be reaching through content
/// that is already most of the way to invisible.
class _ChromeFade extends StatelessWidget {
  const _ChromeFade({super.key, required this.controller, required this.child, this.slideDy = 0});

  final AnimationController controller;
  final Widget child;

  /// How far to slide [child] down (in logical pixels) at full openness - 0 leaves it a
  /// plain fade in place.
  final double slideDy;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final value = controller.value;
        return IgnorePointer(
          ignoring: value > 0,
          child: Opacity(
            opacity: 1 - value,
            child: Transform.translate(offset: Offset(0, value * slideDy), child: child),
          ),
        );
      },
      child: child,
    );
  }
}

/// One bottom-bar destination: icon + label, tinted by selection.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.accent : _fgMuted;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkResponse(
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          radius: 42,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(selected ? activeIcon : icon, size: kBottomNavIconSize, color: color),
              const SizedBox(height: kBottomNavIconLabelGap),
              Text(label, style: kBottomNavLabelStyle.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A resolved place: the "City, Country" label a member sees, paired with the rounded
/// coordinates behind it (2 decimal places, ~1.1km - see _roundCoord). The two are always
/// resolved and cleared together, so a post can never carry coordinates without the label
/// a member can see and remove.
class _PlaceFix {
  const _PlaceFix({required this.place, required this.lat, required this.lng});

  final String place;
  final double lat;
  final double lng;
}

/// The single gate on whether coordinates are sent to [target] with a check-in: only once
/// its server has advertised the recap capability (see [ServerAccount.recapCapable]). This
/// server rejects unknown JSON fields, so sending lat/lng to a server that predates the
/// feature would fail the whole post, not just skip the coordinates - pulled out as its own
/// top-level function (rather than inlined in [_ComposeSheetState._submit]) specifically so
/// this guard is directly testable, see recap_coords_gating_test.dart.
({double? lat, double? lng}) recapCoordsFor(ServerAccount target, double? lat, double? lng) {
  if (!target.recapCapable) return (lat: null, lng: null);
  return (lat: lat, lng: lng);
}

/// Inline compose bottom sheet matching the design. Shown as a modal from the feed's
/// compose button; public so the sheet's own behavior can be exercised on its own.
class ComposeSheet extends ConsumerStatefulWidget {
  const ComposeSheet({super.key});

  @override
  ConsumerState<ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends ConsumerState<ComposeSheet> {
  static const _maxImages = 10;
  final _bodyCtrl = TextEditingController();
  final List<XFile> _images = [];
  // A single clip is exclusive with photos: a post is either a set of photos or one clip.
  // Held pre-encode (already trimmed to <=10s if it needed it); the size encode and poster
  // are computed once at submit and memoized for reuse across cross-post targets.
  XFile? _clip;
  int _clipDurationMs = 0;
  String? _clipEncodedPath;
  List<int>? _clipPoster;
  // A local poster frame for the compose tile, so the picked clip shows its own still rather
  // than a bare play badge on a black box before it is posted.
  Uint8List? _clipPosterPreview;
  bool _processingClip = false;
  // Downloading + staging a picked gif before it joins _images as an ordinary attachment.
  bool _attachingGif = false;
  // The humans the author tags as appearing in the post. Each carries the member id it has
  // in every selected group, so a cross-post can tag the same person on every server.
  final List<TaggablePerson> _tagged = [];
  String? _location; // coarse "City, Country" read from the photos, if any
  String? _locationSource; // path of the photo that supplied _location
  bool _locationCleared = false; // user removed the location manually; don't auto-refill
  bool _resolvingLocation = false;
  // The coordinates behind _location, rounded to 2dp - see _roundCoord. Always cleared
  // alongside _location, and only ever sent to a server that advertises recapCapable.
  double? _lat;
  double? _lng;
  bool _busy = false;
  String? _error;

  // Cross-posting: which groups to share to. Defaults to the viewed group; in the All
  // view nothing is pre-selected and the user must pick. Groups that already accepted
  // the post (partial-failure retry) are locked in [_posted].
  final Set<String> _targets = {};
  final Set<String> _posted = {};
  // A picked photo is compressed once and the JPEG bytes reused for every target group
  // (each group still gets its own upload - media is per-server).
  final Map<String, List<int>> _compressedCache = {};
  // Ties this compose's copies together across groups (and across partial-failure retries).
  // Only applied when sharing to more than one group; a single-group post carries none.
  late final String _crossPostId = _newCrossPostId();

  @override
  void initState() {
    super.initState();
    // Post where you're looking: the shown groups (every signed-in one if none shown).
    // The POST TO section makes the selection obvious and one tap to change.
    _targets.addAll([for (final g in ref.read(multiSessionProvider).composeDefaults) g.id]);
  }

  @override
  void dispose() {
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _toggleTarget(String groupId) {
    if (_posted.contains(groupId)) return; // already posted there (retry state)
    // A clip can't cross-post into a group whose server has no video support; say so rather
    // than let the upload fail there after the fact.
    if (_clip != null && !_targets.contains(groupId)) {
      final g = ref.read(multiSessionProvider).byId(groupId);
      if (g != null && !mediaTypesSupportsVideo(g.mediaTypes)) {
        _toast('${g.displayName} can\'t receive clips yet.');
        return;
      }
    }
    HapticFeedback.selectionClick();
    setState(() {
      if (!_targets.remove(groupId)) _targets.add(groupId);
      // A tag survives a change of targets as long as the person still has an account in
      // one of them; dropping the last group that knows them leaves nothing to tag.
      _tagged.removeWhere((t) => !t.idsByGroup.keys.any(_targets.contains));
      _error = null;
    });
  }

  /// Whether the current selection may take a clip: at least one target group is chosen and
  /// every one of them can store video. Recomputed on demand so the pick entry points agree
  /// with the button gating in build.
  bool get _clipAllowed => clipComposeAllowed([
        for (final g in ref.read(multiSessionProvider).signedIn)
          if (_targets.contains(g.id)) g
      ]);

  // No imageQuality on picks: that re-encodes and strips EXIF, which we need to read the
  // photo's GPS. The server downscales + strips metadata on its end. One picker returns both
  // photos and videos; each is routed to its own flow, never mixed into a single post.
  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickMultipleMedia();
    if (picked.isEmpty || !mounted) return;
    final photos = <XFile>[];
    XFile? video;
    for (final x in picked) {
      if (isVideoPick(x.path)) {
        video ??= x;
      } else {
        photos.add(x);
      }
    }
    // A post is one clip OR a set of photos, never both. When the pick mixes them (or photos
    // are already attached), keep the photos and skip the clip with a clear note.
    if (video != null && (photos.isNotEmpty || _images.isNotEmpty)) {
      _toast('Add photos or one video, not both.');
      video = null;
    }
    if (video != null && !_clipAllowed) {
      _toast('The selected group can\'t receive clips yet.');
      video = null;
    }
    if (video != null) {
      await _handlePickedClip(video.path);
      return;
    }
    if (photos.isEmpty) return;
    setState(() {
      for (final x in photos) {
        if (_images.length < _maxImages) _images.add(x);
      }
    });
    await _resolveLocation();
  }

  /// Opens the gif picker against [active]'s server and, on a pick, downloads the gif and
  /// stages it as an ordinary compose attachment - so submit's existing per-group upload
  /// loop (_uploadCompressed) re-hosts it exactly like a picked photo, no separate path.
  ///
  /// Staging means writing the downloaded bytes to a real temp file and holding it as an
  /// XFile: uploadKindFor/needsReencodeBeforeUpload dispatch on the file's extension, and
  /// _uploadCompressed reads the file from disk for the raw (non-reencoded) path a gif
  /// takes - an in-memory-only XFile has no disk-backed path for that read to open.
  Future<void> _attachGif(ServerAccount active) async {
    final api = ref.read(apiForGroupProvider(active.id));
    final picked =
        await showGifPicker(context, search: (q, page) => api.gifSearch(query: q, page: page));
    if (picked == null || !mounted) return;
    setState(() => _attachingGif = true);
    try {
      final bytes = await ApiClient.downloadExternalGif(picked.gifUrl);
      final dir = await Directory.systemTemp.createTemp('checkin_gif_');
      final file = File('${dir.path}/${picked.id}.gif');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      setState(() {
        // A check-in is one clip or a set of photos, never both; a gif takes the photo slot.
        _clip = null;
        _clipEncodedPath = null;
        _clipPoster = null;
        _clipPosterPreview = null;
        if (_images.length < _maxImages) _images.add(XFile(file.path));
        _attachingGif = false;
      });
    } catch (_) {
      if (mounted) setState(() => _attachingGif = false);
      _toast("Couldn't add that gif. Try again.");
    }
  }

  /// The Camera button's two-way chooser: a photo or a clip, since image_picker has no single
  /// camera call that offers both. The clip option only appears where a clip could be stored
  /// and no photos are already attached.
  Future<void> _pickFromCamera() async {
    final wantVideo = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: context.accent),
              title: const Text('Take Photo', style: TextStyle(color: _fgPrimary)),
              onTap: () => Navigator.of(context).pop(false),
            ),
            if (_clipAllowed && _images.isEmpty)
              ListTile(
                leading: Icon(Icons.videocam_outlined, color: context.accent),
                title: const Text('Record Video', style: TextStyle(color: _fgPrimary)),
                onTap: () => Navigator.of(context).pop(true),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (wantVideo == null || !mounted) return;
    if (wantVideo) {
      await _pickClip(ImageSource.camera);
    } else {
      await _takePhoto();
    }
  }

  Future<void> _takePhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera);
    if (x == null || !mounted) return;
    if (isVideoPick(x.path)) return; // camera handed back a clip: not this button's job
    setState(() {
      if (_images.length < _maxImages) _images.add(x);
    });
    await _resolveLocation();
  }

  /// Picks or records a clip from [source], then hands it to the compose pipeline.
  Future<void> _pickClip(ImageSource source) async {
    final x = await ImagePicker().pickVideo(source: source);
    if (x == null || !mounted) return;
    await _handlePickedClip(x.path);
  }

  /// Runs an already-picked clip through the compose pipeline: read its duration, trim it
  /// down to the cap if it is over, read its recording location (before the encode drops the
  /// metadata), grab a local poster for the tile, and hold it for upload. A clip is exclusive
  /// with photos.
  Future<void> _handlePickedClip(String pickedPath) async {
    setState(() => _processingClip = true);
    try {
      final info = await VideoCompress.getMediaInfo(pickedPath);
      final durationMs = (info.duration ?? 0).round();
      var path = pickedPath;
      var dur = durationMs;
      if (clipNeedsTrim(durationMs)) {
        final window = await _openTrimSheet(pickedPath, durationMs);
        if (window == null) {
          if (mounted) setState(() => _processingClip = false);
          return; // trim sheet cancelled
        }
        path = await ref.read(videoNativeProvider).trim(pickedPath, window.startMs, window.endMs);
        dur = window.endMs - window.startMs;
      }
      if (!mounted) return;
      setState(() {
        _clip = XFile(path);
        _clipDurationMs = dur;
        _clipEncodedPath = null;
        _clipPoster = null;
        _clipPosterPreview = null;
        _images.clear(); // a clip replaces any photos: a post is one or the other
        _processingClip = false;
      });
      // GPS must be read from the trimmed source, before the size encode strips it.
      await _resolveClipLocation(path);
      await _loadClipPosterPreview(path);
    } catch (_) {
      if (mounted) {
        setState(() {
          _processingClip = false;
          _error = "Couldn't prepare that clip. Try another.";
        });
      }
    }
  }

  /// Grabs a local poster frame for the compose tile. Best-effort: a clip with no preview
  /// still shows the play badge and posts fine.
  Future<void> _loadClipPosterPreview(String path) async {
    try {
      final bytes = await VideoCompress.getByteThumbnail(path, quality: 60);
      if (mounted && bytes != null) setState(() => _clipPosterPreview = bytes);
    } catch (_) {
      // No decodable frame: the tile keeps its play-badge-on-dark fallback.
    }
  }

  /// Opens the trim sheet for an over-length clip, returning the chosen <=10s window or null
  /// if the user backed out.
  Future<({int startMs, int endMs})?> _openTrimSheet(String path, int durationMs) {
    return showModalBottomSheet<({int startMs, int endMs})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _TrimSheet(path: path, durationMs: durationMs),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: _bgSurfaceHover));
  }

  /// Read a place label (and its coordinates) from the first image that carries GPS,
  /// remembering which photo it came from. Skips if we already have one or the user
  /// cleared it manually.
  Future<void> _resolveLocation() async {
    if (_locationCleared || _location != null || _images.isEmpty) return;
    setState(() => _resolvingLocation = true);
    _PlaceFix? fix;
    String? source;
    for (final x in _images) {
      fix = await _photoPlace(x.path);
      if (fix != null) {
        source = x.path;
        break;
      }
    }
    if (mounted) {
      setState(() {
        _location = fix?.place;
        _lat = fix?.lat;
        _lng = fix?.lng;
        _locationSource = source;
        _resolvingLocation = false;
      });
    }
  }

  /// Reads the photo's GPS on-device and reverse-geocodes it to a coarse "City, Country",
  /// alongside the coordinates behind it (rounded to 2 decimal places for [_submit] to
  /// send - see [_PlaceFix]). Returns null when there's no location data. Raw
  /// full-precision coordinates never leave the phone.
  Future<_PlaceFix?> _photoPlace(String path) async {
    try {
      final exif = await Exif.fromPath(path);
      final coords = await exif.getLatLong();
      await exif.close();
      if (coords == null) return null;
      return await _placeFix(coords.latitude, coords.longitude);
    } catch (_) {
      return null; // no permission, no GPS, or geocoder unavailable → just skip it
    }
  }

  /// Reverse-geocodes a coordinate to a coarse "City, Country" and pairs it with the
  /// rounded coordinates - null when the geocoder finds nothing, so a post never carries
  /// coordinates without the place label a member can see and remove.
  Future<_PlaceFix?> _placeFix(double lat, double lng) async {
    final place = await _placeFromCoords(lat, lng);
    if (place == null) return null;
    return _PlaceFix(place: place, lat: _roundCoord(lat), lng: _roundCoord(lng));
  }

  /// Reverse-geocodes a coordinate to a coarse "City, Country". Shared by the photo EXIF
  /// path and the clip's MP4-atom path so both post the same kind of label. Null when the
  /// geocoder finds nothing. Raw coordinates never leave the phone.
  Future<String?> _placeFromCoords(double lat, double lng) async {
    try {
      final marks = await placemarkFromCoordinates(lat, lng);
      if (marks.isEmpty) return null;
      final p = marks.first;
      final city = [p.locality, p.subAdministrativeArea, p.administrativeArea]
          .firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
      final parts = <String>[
        if (city != null) city,
        if (p.country != null && p.country!.isNotEmpty) p.country!,
      ];
      return parts.isEmpty ? null : parts.join(', ');
    } catch (_) {
      return null;
    }
  }

  /// Rounds a coordinate to 2 decimal places (~1.1km) before it ever reaches [_submit] -
  /// strictly coarser than the "City, Country" string already sent, so it leaks nothing
  /// new. Stored for the v1.5 map panel; only sent to a server that advertises the recap
  /// capability (see [_submit]).
  double _roundCoord(double v) => (v * 100).round() / 100;

  /// Reads a clip's recording location from its MP4 atom (native, since native_exif is
  /// photo-only) and reverse-geocodes it, offered as the post location exactly as a photo's
  /// is. Skips when the user has cleared the location manually.
  Future<void> _resolveClipLocation(String path) async {
    if (_locationCleared) return;
    setState(() => _resolvingLocation = true);
    _PlaceFix? fix;
    try {
      final coords = await ref.read(videoNativeProvider).location(path);
      if (coords != null) fix = await _placeFix(coords.lat, coords.lng);
    } catch (_) {
      // No location atom, or geocoder unavailable: just post without a place.
    }
    if (mounted) {
      setState(() {
        _location = fix?.place;
        _lat = fix?.lat;
        _lng = fix?.lng;
        _locationSource = fix != null ? path : null;
        _resolvingLocation = false;
      });
    }
  }

  Widget _thumb(int i) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(File(_images[i].path), width: 100, height: 100, fit: BoxFit.cover),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: Semantics(
            button: true,
            label: 'Remove photo',
            child: GestureDetector(
              onTap: () async {
                final removed = _images[i].path;
                setState(() => _images.removeAt(i));
                // If the removed photo is the one that supplied the location, drop it and
                // re-derive from the remaining photos so a deleted photo's place can't stay
                // attached to the post.
                if (removed == _locationSource) {
                  setState(() {
                    _location = null;
                    _locationSource = null;
                    _lat = null;
                    _lng = null;
                  });
                  await _resolveLocation();
                }
              },
              behavior: HitTestBehavior.opaque,
              // 44px hit area; the visual X stays tucked in the top-right corner.
              child: SizedBox(
                width: 44,
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration:
                          const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 15, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The groups this compose will actually post to: the selected ones, minus any that
  /// already accepted the post in a partial-failure retry.
  List<ServerAccount> _selectedTargets() => [
        for (final g in ref.read(multiSessionProvider).signedIn)
          if (_targets.contains(g.id) && !_posted.contains(g.id)) g
      ];

  /// The taggable people of [targets]: every roster merged into one entry per human, so the
  /// picker offers people rather than accounts. A group whose roster can't be fetched simply
  /// contributes nobody, exactly as it does in the feed's people filter.
  Future<List<TaggablePerson>> _loadTaggablePeople(List<ServerAccount> targets) async {
    final lists = await Future.wait([
      for (final g in targets)
        ref.read(groupMembersProvider(g.id).future).catchError((_) => <User>[]),
    ]);
    return mergeTaggablePeople(
      {for (var i = 0; i < targets.length; i++) targets[i].id: lists[i]},
      excludeByGroup: {
        for (final g in targets)
          if (g.user != null) g.id: g.user!.id
      },
    );
  }

  /// Opens the member picker over every selected group's roster, merged into one entry per
  /// human. Excludes the author - the post is implicitly theirs.
  Future<void> _pickPeople() async {
    final targets = _selectedTargets();
    if (targets.isEmpty) return;
    final result = await showModalBottomSheet<List<TaggablePerson>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgMain,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => _TagPeopleSheet(
        people: _loadTaggablePeople(targets),
        groupNames: {for (final g in targets) g.id: g.displayName},
        initial: _tagged,
      ),
    );
    if (result != null && mounted) {
      setState(() => _tagged
        ..clear()
        ..addAll(result));
    }
  }

  /// One cross-post target chip. Posted-to groups are locked with a check so a retry
  /// can't double-post them.
  Widget _targetChip(ServerAccount g) {
    final on = _targets.contains(g.id);
    final done = _posted.contains(g.id);
    final selected = on || done;
    // Cross-post targets are a group-identity surface, so a selected chip wears the group's
    // own color (matching the feed rail/dot) rather than the personal accent.
    final gc = g.displayColor;
    final onGc = gc.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return GestureDetector(
      onTap: () => _toggleTarget(g.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? gc : Colors.transparent,
          border: Border.all(color: selected ? gc : _border),
          borderRadius: BorderRadius.circular(9999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(done ? Icons.check_circle : (on ? Icons.check : Icons.add),
                size: 14, color: selected ? onGc : _fgMuted),
            const SizedBox(width: 6),
            Text(
              g.displayName,
              style: TextStyle(
                color: selected ? onGc : _fgSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Drops the attached clip and everything derived from it: the encode and poster computed
  /// for upload, the tile's preview frame, and the place read off the clip. Shared by the
  /// tile's remove control and by a confirmed replace, so neither can leave a stale poster
  /// or location behind on the next post.
  void _clearClip() {
    setState(() {
      _clip = null;
      _clipEncodedPath = null;
      _clipPoster = null;
      _clipPosterPreview = null;
      _clipDurationMs = 0;
      _location = null;
      _locationSource = null;
      _lat = null;
      _lng = null;
    });
  }

  /// Publishes the check-in to every selected group, one server at a time. Media is
  /// per-server, so images upload once per target. Partial failure keeps the sheet open
  /// with an honest report and turns Share into a retry of only the failed groups.
  Future<void> _submit() async {
    if (_images.isEmpty && _clip == null && _bodyCtrl.text.trim().isEmpty) return;
    final targets = _selectedTargets();
    if (targets.isEmpty) {
      setState(() => _error = 'Pick at least one group to share to.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Encode the clip and pull its poster once, up front, so every cross-post target reuses
    // the same few-MB file and bytes (media is per-server, but the encode is not).
    if (_clip != null) {
      try {
        await _ensureClipEncoded();
      } catch (_) {
        setState(() {
          _busy = false;
          _error = "Couldn't process the clip. Try again.";
        });
        return;
      }
    }
    // One shared id links the copies only when this post goes to more than one group.
    final crossPostId = _targets.length > 1 ? _crossPostId : null;
    final failed = <ServerAccount>[];
    String? failMsg;
    for (final g in targets) {
      try {
        final api = ref.read(apiForGroupProvider(g.id));
        // Tags are this group's own user ids: send each tagged human the id they hold here,
        // and skip the ones with no account on this server. Sending another group's ids
        // would tag whoever happens to own those numbers here.
        final peopleIds = [
          for (final t in _tagged)
            if (t.idIn(g.id) case final id?) id
        ];
        final coords = recapCoordsFor(g, _lat, _lng);
        if (_clip != null) {
          final mediaId = await api.uploadImage(_clipEncodedPath ?? _clip!.path);
          final poster = _clipPoster;
          if (poster != null) {
            // Best-effort: a clip with no stored poster still renders and plays fine, so a
            // failed poster upload must never fail the post.
            await attachPosterBestEffort(() => api.setMediaPoster(mediaId, poster));
          }
          // Server derives the 'video' kind from the stored media; sending a new createPost
          // field would 400 an old server (DisallowUnknownFields), so kind stays 'image'.
          await api.createPost(
              kind: 'image',
              body: _bodyCtrl.text.trim(),
              mediaIds: [mediaId],
              location: _location,
              peopleIds: peopleIds,
              crossPostId: crossPostId,
              lat: coords.lat,
              lng: coords.lng);
        } else if (_images.isNotEmpty) {
          final ids = <int>[];
          for (final x in _images) {
            ids.add(await _uploadCompressed(api, x));
          }
          await api.createPost(
              kind: 'image',
              body: _bodyCtrl.text.trim(),
              mediaIds: ids,
              location: _location,
              peopleIds: peopleIds,
              crossPostId: crossPostId,
              lat: coords.lat,
              lng: coords.lng);
        } else {
          await api.createPost(
              kind: 'text',
              body: _bodyCtrl.text.trim(),
              peopleIds: peopleIds,
              crossPostId: crossPostId);
        }
        _posted.add(g.id);
      } on DioException catch (e) {
        failed.add(g);
        final data = e.response?.data;
        if (data is Map && data['error'] is String) failMsg = data['error'] as String;
      } catch (_) {
        failed.add(g);
      }
    }
    if (!mounted) return;
    if (failed.isEmpty) {
      HapticFeedback.lightImpact();
      Navigator.of(context).pop(true);
      return;
    }
    final failedNames = [for (final g in failed) g.displayName].join(', ');
    final postedNames = [
      for (final g in ref.read(multiSessionProvider).signedIn)
        if (_posted.contains(g.id)) g.displayName
    ].join(', ');
    // Never surface a raw server string for a clip failure: a message like "video is longer
    // than 12 seconds" is internal and, with the server's mvhd fix, a <=10s clip should not
    // reach that backstop anyway. Show a friendly line instead. Photos keep the server's
    // wording, which is already member-facing.
    final firstShareError = _clip != null
        ? "Couldn't post that clip. Try a shorter one."
        : (failMsg ?? "Couldn't share to $failedNames. Check your connection and retry.");
    setState(() {
      _busy = false;
      _error = _posted.isEmpty
          ? firstShareError
          : "Posted to $postedNames. Couldn't reach $failedNames - tap Retry to try again.";
    });
  }

  /// Downscales and transcodes a picked photo to JPEG before upload. This handles iPhone
  /// HEIC (which the server can't decode) and keeps uploads small so the server never has
  /// to decode a full-resolution image. Location is already resolved from the original by
  /// this point. Falls back to uploading the original if compression isn't available.
  Future<int> _uploadCompressed(ApiClient api, XFile x) async {
    // Straight to the raw path for the formats re-encoding would ruin (see
    // needsReencodeBeforeUpload); the server stores those as they arrive.
    if (!needsReencodeBeforeUpload(x.path)) return api.uploadImage(x.path);
    List<int>? bytes;
    try {
      bytes = _compressedCache[x.path];
      if (bytes == null) {
        bytes = await FlutterImageCompress.compressWithFile(
          x.path,
          minWidth: 1600,
          minHeight: 1600,
          quality: 88,
          format: CompressFormat.jpeg,
        );
        if (bytes != null) _compressedCache[x.path] = bytes;
      }
    } catch (_) {
      // Unsupported source/platform - fall through and let the server try the original.
    }
    // Outside the try: only compression gets the fallback. An upload that fails must
    // surface, not silently re-upload the full-resolution original.
    if (bytes != null) return api.uploadImageBytes(bytes);
    return api.uploadImage(x.path);
  }

  /// Size-encodes the held clip to ~720p (a few MB) via the platform encoder and grabs a
  /// poster frame, once, memoizing both so every cross-post target reuses the same file and
  /// bytes. The poster is best-effort even here: a failure to grab it just means no
  /// pre-play still. Falls back to the pre-encode file if the encoder yields nothing.
  Future<void> _ensureClipEncoded() async {
    final clip = _clip;
    if (clip == null || _clipEncodedPath != null) return;
    final info = await VideoCompress.compressVideo(
      clip.path,
      // MediumQuality looked muddy on device; a fixed 720p is clean and predictable and a
      // 10s clip stays comfortably under the 25MB cap. Tunable after device review.
      quality: VideoQuality.Res1280x720Quality,
    );
    _clipEncodedPath = info?.path ?? clip.path;
    try {
      final bytes = await VideoCompress.getByteThumbnail(_clipEncodedPath!, quality: 80);
      if (bytes != null) _clipPoster = bytes;
    } catch (_) {
      // No poster frame: the clip still posts and plays, the feed just has nothing to show
      // for it until first play.
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(multiSessionProvider);
    final me = ref.watch(currentAccountProvider)?.user;
    final hasContent = (_bodyCtrl.text.trim().isNotEmpty || _images.isNotEmpty || _clip != null) &&
        _targets.isNotEmpty;
    final selectedTargets = [
      for (final g in session.signedIn)
        if (_targets.contains(g.id)) g
    ];
    final gifAllowed = gifComposeAllowed(session.current, selectedTargets);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final retrying = _posted.isNotEmpty;
    // Give the sheet a comfortable working height (roughly half the screen) in every state so
    // it never opens as a cramped strip. The keyboard inset is subtracted from the minimum so
    // the content area plus the keyboard-avoidance padding still sum to about the same height,
    // rather than overflowing when the composer is focused.
    final minSheetHeight =
        (MediaQuery.sizeOf(context).height * 0.55 - bottomInset).clamp(0.0, double.infinity);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minSheetHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 14),
              decoration: BoxDecoration(
                color: _border,
                borderRadius: BorderRadius.circular(9999),
              ),
            ),
            // Title row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: _fgSecondary,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  ),
                  const Expanded(
                    child: Text(
                      'New check-in',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _bodyCtrl,
                    builder: (_, __, ___) => TextButton(
                      onPressed: hasContent && !_busy ? _submit : null,
                      style: TextButton.styleFrom(
                        backgroundColor: hasContent ? context.accent : _bgSurfaceHover,
                        foregroundColor: hasContent ? context.onAccent : _fgMuted,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9999)),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: _busy
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: context.onAccent))
                          : Text(
                              // Say how many groups this goes to, so cross-posting is
                              // never a surprise.
                              retrying
                                  ? 'Retry'
                                  : (_targets.length > 1 ? 'Share (${_targets.length})' : 'Share'),
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    ),
                  ),
                ],
              ),
            ),
            // Cross-post targets: one pill per connected group, under an explicit POST TO
            // label so "where is this going" is a first-class choice, not an afterthought.
            // Hidden with a single group (nothing to choose). Groups already posted to
            // (partial-failure retry) show a check and lock.
            if (session.signedIn.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('POST TO',
                            style: TextStyle(
                                color: _fgMuted,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                letterSpacing: 0.4)),
                        if (_targets.isEmpty) ...[
                          const SizedBox(width: 8),
                          const Text('pick at least one group',
                              style: TextStyle(color: _fgMuted, fontSize: 12)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [for (final g in session.signedIn) _targetChip(g)],
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            // Image previews - a removable thumbnail strip.
            if (_images.isNotEmpty)
              SizedBox(
                height: 100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _images.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => _thumb(i),
                ),
              ),
            // Clip preview - one removable tile (a clip is exclusive with photos).
            if (_clip != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(alignment: Alignment.centerLeft, child: _clipTile()),
              ),
            // Detected location (read from the photos or the clip, removable before posting)
            if ((_images.isNotEmpty || _clip != null) && (_resolvingLocation || _location != null))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(
                  children: [
                    Icon(Icons.place_outlined, size: 16, color: context.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _resolvingLocation ? 'Checking location…' : _location!,
                        style: const TextStyle(color: _fgSecondary, fontSize: 13),
                      ),
                    ),
                    if (_location != null && !_resolvingLocation)
                      GestureDetector(
                        onTap: () => setState(() {
                          _location = null;
                          _locationSource = null;
                          _locationCleared = true;
                          _lat = null;
                          _lng = null;
                        }),
                        behavior: HitTestBehavior.opaque,
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(Icons.close, size: 16, color: _fgMuted),
                        ),
                      ),
                  ],
                ),
              ),
            // Text input
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (me != null) ...[
                    UserAvatar(
                        name: me.name, size: 38, mediaId: me.profileMediaId, colorSeed: me.id),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: TextField(
                      controller: _bodyCtrl,
                      onChanged: (_) => setState(() {}),
                      minLines: 3,
                      maxLines: 6,
                      style: const TextStyle(color: _fgPrimary, fontSize: 16, height: 1.5),
                      decoration: const InputDecoration(
                        hintText: "What's going on?",
                        hintStyle: TextStyle(color: _fgMuted),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.only(top: 6),
                      ),
                    ),
                  ),
                  // Right-aligned inside the input area, matching the comment field's gif
                  // icon. Hidden entirely rather than disabled: a group whose server can't
                  // search or store a gif has no working action to grey out.
                  if (gifAllowed)
                    Padding(
                      padding: const EdgeInsets.only(left: 2, top: 2),
                      child: IconButton(
                        onPressed: _attachingGif ? null : () => _attachGif(session.current!),
                        tooltip: 'Add a gif',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: _attachingGif
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: context.accent),
                              )
                            : Icon(Icons.gif_box_outlined, color: context.accent, size: 24),
                      ),
                    ),
                ],
              ),
            ),
            // Tag people - who's in this post (drives the feed's "include posts they're in").
            // The picker merges the rosters of every selected group, so a cross-post tags the
            // same humans in each of them; with no group picked there is no roster to offer.
            if (_targets.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: InkWell(
                  onTap: _pickPeople,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.person_add_alt_1_outlined, size: 18, color: context.accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _tagged.isEmpty
                              ? const Text('Tag people',
                                  style: TextStyle(color: _fgSecondary, fontSize: 14))
                              : Text(
                                  [for (final t in _tagged) t.name].join(', '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: _fgPrimary, fontSize: 14),
                                ),
                        ),
                        if (_tagged.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Text('${_tagged.length}',
                                style: const TextStyle(color: _fgMuted, fontSize: 13)),
                          ),
                        const Icon(Icons.chevron_right, size: 18, color: _fgMuted),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_error!, style: const TextStyle(color: kLike, fontSize: 13)),
              ),
            // Divider + media buttons: one Gallery (photos and videos) and one Camera (photo or
            // clip via a chooser). The pick entry points handle the one-clip-or-photos rule and
            // the video-capable-group gating.
            const Divider(color: _border, height: 24),
            // The row is only ever replaced by the preparing-clip progress, never by an
            // attached clip: swapping a clip is a pick away (see [ComposeMediaButtons]).
            if (_processingClip)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: context.accent),
                    ),
                    const SizedBox(width: 10),
                    const Text('Preparing clip…',
                        style: TextStyle(color: _fgSecondary, fontSize: 13)),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: ComposeMediaButtons(
                  hasClip: _clip != null,
                  hasPhotos: _images.isNotEmpty,
                  onGallery: _pickFromGallery,
                  onCamera: _pickFromCamera,
                  onReplaceClip: _clearClip,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The clip preview tile: a play glyph and the clip's length over a dark backdrop, with a
  /// remove control that clears the clip (and its detected location) back to an empty post.
  Widget _clipTile() {
    final label = PostMedia(id: 0, mime: 'video/mp4', durationMs: _clipDurationMs).durationLabel;
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 140,
            height: 100,
            color: const Color(0xFF14161A),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The clip's own poster frame, once decoded, sits behind the play badge so the
                // tile is not a bare black box while composing.
                if (_clipPosterPreview != null)
                  Image.memory(_clipPosterPreview!, fit: BoxFit.cover),
                const Center(
                  child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34),
                ),
              ],
            ),
          ),
        ),
        if (label.isNotEmpty)
          Positioned(
            bottom: 6,
            left: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(9999),
              ),
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ),
        Positioned(
          top: 0,
          right: 0,
          child: Semantics(
            button: true,
            label: 'Remove clip',
            child: GestureDetector(
              onTap: _clearClip,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration:
                          const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 15, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Multi-select picker for tagging who appears in a post. One row per human, merged across
/// every group the post is going to, filtered by a search box; returns the chosen people
/// (or null on cancel). A person the post's other groups don't know is still taggable - the
/// row says which groups they're missing from, and their copies there go out without them.
class _TagPeopleSheet extends StatefulWidget {
  const _TagPeopleSheet({required this.people, required this.groupNames, required this.initial});

  final Future<List<TaggablePerson>> people;

  /// The groups this post is going to: id -> display name, in the order they're posted to.
  final Map<String, String> groupNames;

  final List<TaggablePerson> initial;

  @override
  State<_TagPeopleSheet> createState() => _TagPeopleSheetState();
}

class _TagPeopleSheetState extends State<_TagPeopleSheet> {
  final _selected = <String, TaggablePerson>{};
  String _query = '';

  @override
  void initState() {
    super.initState();
    for (final t in widget.initial) {
      _selected[t.key] = t;
    }
    // The roster decides which id a person holds in which group, so a selection carried in
    // from before the targets changed has a stale id map. Re-bind every selection to the
    // freshly merged entry, and drop anyone no selected group knows any more - there would
    // be no id left to tag them with. Load errors surface through the FutureBuilder.
    unawaited(widget.people.then((people) {
      if (!mounted) return;
      final byKey = {for (final p in people) p.key: p};
      setState(() {
        _selected
          ..removeWhere((key, _) => !byKey.containsKey(key))
          ..updateAll((key, _) => byKey[key]!);
      });
    }, onError: (_) {}));
  }

  /// The light note under a name: which of the post's groups have no account for this
  /// person. Silent when the post only goes to one group - there is nothing to compare.
  String _missingNote(TaggablePerson p) {
    if (widget.groupNames.length < 2) return '';
    final missing = [
      for (final id in p.missingFrom(widget.groupNames.keys)) widget.groupNames[id]!
    ];
    return missing.isEmpty ? '' : 'not in ${missing.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (context, scrollCtrl) => Column(
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 12),
              decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(9999)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Tag people',
                        style: TextStyle(
                            color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_selected.values.toList()),
                    style: TextButton.styleFrom(
                      backgroundColor: context.accent,
                      foregroundColor: context.onAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9999)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_selected.isEmpty ? 'Done' : 'Done (${_selected.length})',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                style: const TextStyle(color: _fgPrimary, fontSize: 14),
                cursorColor: context.accent,
                decoration: InputDecoration(
                  hintText: 'Search members…',
                  hintStyle: const TextStyle(color: _fgMuted),
                  prefixIcon: const Icon(Icons.search, color: _fgMuted, size: 20),
                  filled: true,
                  fillColor: _bgSurface,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _border),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<TaggablePerson>>(
                future: widget.people,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return Center(child: CircularProgressIndicator(color: context.accent));
                  }
                  if (snap.hasError) {
                    return const Center(
                        child:
                            Text('Could not load members.', style: TextStyle(color: _fgSecondary)));
                  }
                  final people = [
                    for (final p in snap.data ?? const <TaggablePerson>[])
                      if (_query.isEmpty || p.name.toLowerCase().contains(_query)) p
                  ];
                  if (people.isEmpty) {
                    return const Center(
                        child: Text('No members found.', style: TextStyle(color: _fgMuted)));
                  }
                  return ListView.builder(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: people.length,
                    itemBuilder: (_, i) {
                      final p = people[i];
                      final on = _selected.containsKey(p.key);
                      final note = _missingNote(p);
                      return ListTile(
                        onTap: () => setState(() {
                          if (on) {
                            _selected.remove(p.key);
                          } else {
                            _selected[p.key] = p;
                          }
                        }),
                        leading: UserAvatar(
                            name: p.name,
                            size: 38,
                            mediaId: p.photoId,
                            groupId: p.photoGroupId,
                            // Seeded from the group the name came from, so an initial wears
                            // the same color the feed already gives that person there.
                            colorSeed: p.idsByGroup.values.first),
                        title:
                            Text(p.name, style: const TextStyle(color: _fgPrimary, fontSize: 15)),
                        subtitle: note.isEmpty
                            ? null
                            : Text(note, style: const TextStyle(color: _fgMuted, fontSize: 12)),
                        trailing: Icon(
                          on ? Icons.check_circle : Icons.circle_outlined,
                          color: on ? context.accent : _fgMuted,
                          size: 22,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Trims a clip down to a <=10s window before it is posted. A filmstrip of frames spans the
/// whole clip; two independent handles pick the window - the left sets the start, the right
/// sets the end, each freely draggable - so any span from 1s up to the 10s cap can be chosen.
/// Dragging between the handles slides that window along the clip at a fixed length. The
/// preview plays the selected [start, end] range so the pick can be reviewed before Trim.
/// An edge drag is clamped through [clampTrimWindow], which moves only the dragged edge and
/// can never let the window exceed the cap or run off the clip; a middle drag goes through
/// [shiftTrimWindow], which keeps the span. Returns (startMs, endMs) on Trim, or null on
/// cancel.
class _TrimSheet extends StatefulWidget {
  const _TrimSheet({required this.path, required this.durationMs});

  final String path;
  final int durationMs;

  @override
  State<_TrimSheet> createState() => _TrimSheetState();
}

class _TrimSheetState extends State<_TrimSheet> {
  static const _frames = 8;
  late int _startMs;
  late int _endMs;
  final List<Uint8List?> _thumbs = List.filled(_frames, null);
  VideoPlayerController? _preview;
  bool _previewReady = false;
  bool _playing = false;
  // The preview starts muted so opening the sheet is never a jump-scare; the toggle turns
  // sound on to review audio before posting.
  bool _muted = true;

  @override
  void initState() {
    super.initState();
    // Two independent edges, seeded with the widest legal window (the head of the clip up to
    // the cap). The handles move each edge on its own from here.
    _startMs = 0;
    _endMs = widget.durationMs < kMaxClipMs ? widget.durationMs : kMaxClipMs;
    // Thumbs load in the background; the handles are interactive immediately against the
    // placeholder strip, so a long clip never blocks dragging while frames decode.
    _loadThumbs();
    _initPreview();
  }

  @override
  void dispose() {
    _preview?.removeListener(_watchPreview);
    _preview?.dispose();
    super.dispose();
  }

  Future<void> _loadThumbs() async {
    for (var i = 0; i < _frames; i++) {
      final at = (widget.durationMs * i / (_frames - 1)).round();
      try {
        final bytes = await VideoCompress.getByteThumbnail(widget.path, quality: 40, position: at);
        if (!mounted) return;
        setState(() => _thumbs[i] = bytes);
      } catch (_) {
        // A frame that will not decode just leaves a gap in the strip.
      }
    }
  }

  void _initPreview() {
    final controller = VideoPlayerController.file(File(widget.path));
    _preview = controller;
    controller.initialize().then((_) {
      if (!mounted) return;
      controller.setVolume(_muted ? 0 : 1);
      controller.seekTo(Duration(milliseconds: _startMs));
      controller.addListener(_watchPreview);
      setState(() => _previewReady = true);
    }).catchError((_) {
      // No platform player (test/unsupported): the strip alone drives the selection.
    });
  }

  // Keeps preview playback inside the chosen window: loop back to the start once it reaches
  // the selected end, and mirror the play/pause state into the button.
  void _watchPreview() {
    final controller = _preview;
    if (controller == null || !_previewReady) return;
    final playing = controller.value.isPlaying;
    if (playing && controller.value.position.inMilliseconds >= _endMs) {
      controller.seekTo(Duration(milliseconds: _startMs));
    }
    if (playing != _playing && mounted) setState(() => _playing = playing);
  }

  void _togglePlay() {
    final controller = _preview;
    if (controller == null || !_previewReady) return;
    if (controller.value.isPlaying) {
      controller.pause();
      return;
    }
    final pos = controller.value.position.inMilliseconds;
    if (pos < _startMs || pos >= _endMs) {
      controller.seekTo(Duration(milliseconds: _startMs));
    }
    controller.setVolume(_muted ? 0 : 1);
    controller.play();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _preview?.setVolume(_muted ? 0 : 1);
  }

  void _seekPreview(int ms) {
    final controller = _preview;
    if (controller != null && _previewReady) controller.seekTo(Duration(milliseconds: ms));
  }

  // The left handle moves only the start; the end stays put (clampTrimWindow moves the start
  // edge to honor the 1s..10s span against the fixed end).
  void _setStart(int ms) {
    final window = clampTrimWindow(ms, _endMs, widget.durationMs, moved: TrimEdge.start);
    setState(() {
      _startMs = window.startMs;
      _endMs = window.endMs;
    });
    _seekPreview(_startMs);
  }

  // Dragging between the handles slides the window as a whole (see [shiftTrimWindow]): both
  // edges move, the span is untouched, and the ends of the clip stop it.
  void _shiftWindow(int deltaMs) {
    final window = shiftTrimWindow(_startMs, _endMs, deltaMs, widget.durationMs);
    if (window.startMs == _startMs) return;
    setState(() {
      _startMs = window.startMs;
      _endMs = window.endMs;
    });
    _seekPreview(_startMs);
  }

  // The right handle moves only the end; the start stays put.
  void _setEnd(int ms) {
    final window = clampTrimWindow(_startMs, ms, widget.durationMs, moved: TrimEdge.end);
    setState(() {
      _startMs = window.startMs;
      _endMs = window.endMs;
    });
  }

  int _dxToMs(double dx, double width) => width <= 0 ? 0 : (dx / width * widget.durationMs).round();

  @override
  Widget build(BuildContext context) {
    final selectedMs = _endMs - _startMs;
    // isScrollControlled makes the sheet full-height, so its own top reaches under the status
    // bar; pad by the status-bar inset so the header always clears the clock/notch.
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration:
                    BoxDecoration(color: _border, borderRadius: BorderRadius.circular(9999)),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(foregroundColor: _fgSecondary),
                    child: const Text('Cancel'),
                  ),
                  Expanded(
                    child: Text(
                      'Trim to ${(selectedMs / 1000).toStringAsFixed(1)}s',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop((startMs: _startMs, endMs: _endMs)),
                    style: TextButton.styleFrom(
                      backgroundColor: context.accent,
                      foregroundColor: context.onAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9999)),
                    ),
                    child: const Text('Trim', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _previewPane(context),
              const SizedBox(height: 14),
              SizedBox(height: 56, child: _filmstrip()),
              const SizedBox(height: 8),
              const Text(
                'Drag the ends to pick 1 to 10 seconds, or the middle to slide the window. '
                'Tap play to preview.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _fgMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The preview video with a centered play/pause control and a mute toggle, so the chosen
  /// window can be watched (and heard) before committing to it.
  ///
  /// Height-capped at a bit over half the screen. Left to its own aspect ratio a portrait
  /// clip claims nearly the whole sheet and pushes the filmstrip - the part being edited -
  /// to the bottom edge; inside the cap it letterboxes instead, and the header, strip and
  /// hint all sit comfortably, which is the proportion Instagram's trimmer keeps.
  Widget _previewPane(BuildContext context) {
    final ready = _previewReady && _preview != null;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.58),
      child: AspectRatio(
        aspectRatio: ready ? _preview!.value.aspectRatio : 16 / 9,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (ready) VideoPlayer(_preview!) else const ColoredBox(color: Color(0xFF14161A)),
            if (ready)
              GestureDetector(
                onTap: _togglePlay,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white, size: 32),
                ),
              ),
            if (ready)
              Positioned(
                right: 6,
                bottom: 6,
                child: Semantics(
                  button: true,
                  label: _muted ? 'Unmute preview' : 'Mute preview',
                  child: GestureDetector(
                    onTap: _toggleMute,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration:
                          const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                          color: Colors.white, size: 18),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _filmstrip() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final startFrac = widget.durationMs == 0 ? 0.0 : _startMs / widget.durationMs;
        final endFrac = widget.durationMs == 0 ? 1.0 : _endMs / widget.durationMs;
        const handle = 12.0;
        return Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < _frames; i++)
                  Expanded(
                    child: _thumbs[i] == null
                        ? const ColoredBox(color: Color(0xFF14161A))
                        : Image.memory(_thumbs[i]!, fit: BoxFit.cover, height: 56),
                  ),
              ],
            ),
            // The unselected ends dimmed so the chosen window reads clearly.
            Positioned.fill(
              child: Row(
                children: [
                  SizedBox(
                    width: startFrac * width,
                    child: const ColoredBox(color: Colors.black54),
                  ),
                  const Expanded(child: SizedBox()),
                  SizedBox(
                    width: (1 - endFrac) * width,
                    child: const ColoredBox(color: Colors.black54),
                  ),
                ],
              ),
            ),
            // The selected region itself: dragging it moves the whole window, so a window
            // that is already the right length can be slid to a different moment without
            // rebuilding it edge by edge. Framed top and bottom so it reads as one draggable
            // block. Below the handles in the stack, so an edge drag stays an edge drag.
            Positioned(
              left: (startFrac * width).clamp(0.0, width),
              width: ((endFrac - startFrac) * width).clamp(0.0, width),
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => _shiftWindow(_dxToMs(d.delta.dx, width)),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.symmetric(
                      horizontal: BorderSide(color: context.accent, width: 2),
                    ),
                  ),
                ),
              ),
            ),
            // Left handle: slides the whole window's start.
            Positioned(
              left: (startFrac * width - handle).clamp(0.0, width - handle),
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onHorizontalDragUpdate: (d) =>
                    _setStart(_dxToMs(startFrac * width + d.delta.dx, width)),
                child: _handleBar(context),
              ),
            ),
            // Right handle: shortens the tail.
            Positioned(
              left: (endFrac * width).clamp(0.0, width - handle),
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onHorizontalDragUpdate: (d) =>
                    _setEnd(_dxToMs(endFrac * width + d.delta.dx, width)),
                child: _handleBar(context),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _handleBar(BuildContext context) {
    return Container(
      width: 12,
      decoration: BoxDecoration(
        color: context.accent,
        borderRadius: BorderRadius.circular(3),
      ),
      child: const Icon(Icons.drag_indicator, size: 12, color: Colors.white),
    );
  }
}

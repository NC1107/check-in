import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/auth_image.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail_screen.dart';

// Theme tokens (centralized in theme/tokens.dart).
const _bgMain = kBgMain;
const _bgSurface = kBgSurface;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;

/// How far open (as a fraction of the controller's 0..1 range, itself a fraction of the
/// screen's width - the surface slides exactly one screen width) a drag has to travel before
/// release commits it, absent a fast flick. See [settleMemoriesTarget].
const kMemoriesOpenThreshold = 0.35;

/// A release faster than this many logical pixels/second commits in its own direction even
/// from a drag that never reached [kMemoriesOpenThreshold] - so a quick flick opens (or
/// closes) the surface from a short drag, the way a drawer or bottom sheet settles.
const kMemoriesFlickVelocity = 500.0;

/// The handle's tappable/draggable strip width - at least Apple's 44pt touch-target
/// guidance, well past the 4px-wide visible pill it centers (see [MemoriesHandle]).
///
/// The handle is laid out as an overlay, not a Row child (see home_shell.dart): it is
/// positioned on top of the bottom bar's leading edge and takes no layout space of its own,
/// so this width only ever sizes its own hit-testable strip and never affects where the
/// Feed/You tabs or the FAB notch sit. An earlier version made the handle a real Row
/// participant sized to this constant (plus a mirrored spacer to keep the FAB notch
/// centered) - that kept the notch centered but still measurably shifted the Feed and You
/// icons inward, which is exactly the kind of shift this "invisible" feature must not cause.
const kMemoriesHandleWidth = 44.0;

/// Decides whether an in-progress interactive drag of the Memories surface should settle
/// open (1.0) or closed (0.0) once the finger lifts. [position] is the drag's current
/// progress (0=closed..1=open); [velocityPxPerSec] is the horizontal velocity at release
/// (positive = rightward/opening). A pure function so the settle rule itself is directly
/// unit-testable without pumping a widget tree.
double settleMemoriesTarget(double position, double velocityPxPerSec) {
  if (velocityPxPerSec.abs() >= kMemoriesFlickVelocity) {
    return velocityPxPerSec > 0 ? 1.0 : 0.0;
  }
  return position >= kMemoriesOpenThreshold ? 1.0 : 0.0;
}

/// Drives one [AnimationController] from a horizontal drag gesture and settles it open or
/// closed on release (see [settleMemoriesTarget]). Shared by the handle (which only ever
/// opens) and the surface itself (which only ever closes) - both drag the same controller
/// the same way, so this is the one place that logic is written.
///
/// Reduced motion ([MediaQuery.disableAnimations]) still has to open/close from the same
/// drag, just without live tracking: dragging must not move the surface frame-by-frame, but
/// releasing past the threshold (or on a flick) must still commit, snapping straight there.
/// So the cumulative distance is always tracked in [_dragAccum]; only whether that also
/// drives the controller's value live is gated on reduced motion.
class MemoriesDragDriver {
  MemoriesDragDriver(this.controller);

  final AnimationController controller;
  double _dragAccum = 0;

  // Whether a drag is actually in progress - i.e. [start] has fired and neither [end] nor
  // [cancel] has settled it since. This is what [cancel] uses to tell a genuinely
  // interrupted drag apart from an ordinary tap: Flutter's DragGestureRecognizer invokes
  // onCancel any time a pointer that could have started a drag goes away WITHOUT one ever
  // starting - which includes every plain tap that a competing tap recognizer wins instead
  // (see DragGestureRecognizer.didStopTrackingLastPointer). Without this guard, tapping
  // anything wrapped by the same GestureDetector - "Give me a memory", "Another", the close
  // button - would fire a spurious cancel and yank the surface back toward closed.
  bool _dragging = false;

  void start() {
    _dragging = true;
    _dragAccum = controller.value;
  }

  void update(DragUpdateDetails details, double screenWidth, bool reduceMotion) {
    final deltaFraction = (details.primaryDelta ?? 0) / screenWidth;
    _dragAccum = (_dragAccum + deltaFraction).clamp(0.0, 1.0);
    if (!reduceMotion) controller.value = _dragAccum;
  }

  void end(DragEndDetails details, bool reduceMotion) {
    _dragging = false;
    final velocity = details.primaryVelocity ?? 0;
    final target = settleMemoriesTarget(_dragAccum, velocity);
    controller.animateTo(target,
        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOut);
  }

  /// Settles the drag exactly like [end] with zero velocity, for a drag the platform
  /// cancelled outright mid-gesture (the app backgrounded, another recognizer stole the
  /// arena after already losing to this one) rather than one that reached a normal
  /// pointer-up. Without this the controller would simply be left wherever the drag had
  /// got to - no [end] ever fires for a cancelled gesture - and the surface could sit
  /// part-open indefinitely with nothing to nudge it shut or open.
  ///
  /// A no-op when no drag was actually in progress (see [_dragging]'s doc comment) - the far
  /// more common reason this fires is an ordinary tap that a sibling tap recognizer won
  /// instead, which must not move the surface at all.
  void cancel(bool reduceMotion) {
    if (!_dragging) return;
    _dragging = false;
    final target = settleMemoriesTarget(_dragAccum, 0);
    controller.animateTo(target,
        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOut);
  }
}

/// The memory's age the way a person would say it: "3 years ago" once the gap crosses a
/// year, "last October" for anything further back but still within the last year, otherwise
/// a weeks-ago count. The server never returns a post younger than its 14-day recency floor,
/// so this never has to cover "today"/"3d ago" - that end of the scale already belongs to
/// the existing relative-time helpers (see post_card.dart's `_relativeTime`).
String memoryAgeLabel(DateTime createdAt, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final local = createdAt.toLocal();
  var months = (n.year - local.year) * 12 + (n.month - local.month);
  if (n.day < local.day) months -= 1;
  if (months < 1) {
    final weeks = max(1, (n.difference(local).inDays / 7).floor());
    return weeks == 1 ? '1 week ago' : '$weeks weeks ago';
  }
  if (months < 12) {
    return 'last ${DateFormat.MMMM().format(local)}';
  }
  final years = months ~/ 12;
  return years == 1 ? '1 year ago' : '$years years ago';
}

/// The small, unlabeled grab handle overlaid on the bottom bar's leading edge, on top of
/// (not beside) the Feed tab - see home_shell.dart, which stacks this over the bar rather
/// than laying it out as a Row child, precisely so it never shifts the Feed/You icons or the
/// FAB notch. Deliberately not a [_NavItem] lookalike - it must not read as a third
/// destination. Absent entirely when no shown group advertises the Memories capability, per
/// [MultiSession.memoriesCapableShownGroups].
///
/// Opens on a plain tap (the accessibility path - VoiceOver/Switch Control and anyone who
/// never discovers the drag both go through this) and on an interactive rightward drag past
/// [kMemoriesOpenThreshold] or a rightward flick.
class MemoriesHandle extends ConsumerStatefulWidget {
  const MemoriesHandle({super.key, required this.controller});

  final AnimationController controller;

  @override
  ConsumerState<MemoriesHandle> createState() => _MemoriesHandleState();
}

class _MemoriesHandleState extends ConsumerState<MemoriesHandle> {
  late final _drag = MemoriesDragDriver(widget.controller);

  void _open(bool reduceMotion) {
    HapticFeedback.selectionClick();
    widget.controller.animateTo(1,
        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final capable =
        ref.watch(multiSessionProvider.select((s) => s.memoriesCapableShownGroups.isNotEmpty));
    // An overlay, not a Row child (see the class doc comment) - shrinking to nothing here
    // costs no layout, only removes the gesture surface and lets taps fall through to
    // whatever the handle was sitting on top of.
    if (!capable) return const SizedBox.shrink();

    final width = MediaQuery.sizeOf(context).width;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Semantics(
      button: true,
      label: 'Memories',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _open(reduceMotion),
        onHorizontalDragStart: (_) => _drag.start(),
        onHorizontalDragUpdate: (d) => _drag.update(d, width, reduceMotion),
        onHorizontalDragEnd: (d) => _drag.end(d, reduceMotion),
        onHorizontalDragCancel: () => _drag.cancel(reduceMotion),
        child: SizedBox(
          width: kMemoriesHandleWidth,
          height: 64,
          // The visible pill stays exactly 4x26, centered in the wider tap target - only the
          // grabbable area grows, never the look.
          child: Center(
            child: Container(
              width: 4,
              height: 26,
              decoration: BoxDecoration(
                color: _fgMuted.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(9999),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The hidden Memories surface: slides in from the left over the feed as [controller] goes
/// 0→1, tracking a drag live except under reduced motion (see [MemoriesDragDriver]).
/// [onClose] settles the controller back to 0 - shared by the header's close button and a
/// leftward drag anywhere on the surface.
///
/// Also owns the Android back interception: while [controller] is anywhere above closed,
/// system back must close the surface rather than pop the route (or exit the app, on a
/// single-route stack) - self-contained here via [PopScope] rather than pushed up into
/// home_shell.dart, so this one widget is independently responsible for, and testable for,
/// that contract.
class MemoriesSurface extends StatefulWidget {
  const MemoriesSurface({super.key, required this.controller, required this.onClose});

  final AnimationController controller;
  final VoidCallback onClose;

  @override
  State<MemoriesSurface> createState() => _MemoriesSurfaceState();
}

class _MemoriesSurfaceState extends State<MemoriesSurface> {
  // Seeded from the controller's value at mount time (not just future changes to it): the
  // listener below only ever fires on a change, so without this a controller that already
  // started above 0 would leave _open - and therefore PopScope's canPop - wrong until the
  // next drag or animation.
  late bool _open = widget.controller.value > 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onValueChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValueChanged);
    super.dispose();
  }

  void _onValueChanged() {
    final open = widget.controller.value > 0;
    if (open != _open) setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onClose();
      },
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, child) {
          final value = widget.controller.value;
          // Closed (value == 0) lets touches fall through to the feed underneath rather
          // than sitting on top of it invisibly.
          return IgnorePointer(
            ignoring: value == 0,
            child: Transform.translate(offset: Offset(-width * (1 - value), 0), child: child),
          );
        },
        child: _MemoriesSurfaceContent(controller: widget.controller, onClose: widget.onClose),
      ),
    );
  }
}

class _MemoriesSurfaceContent extends StatefulWidget {
  const _MemoriesSurfaceContent({required this.controller, required this.onClose});

  final AnimationController controller;
  final VoidCallback onClose;

  @override
  State<_MemoriesSurfaceContent> createState() => _MemoriesSurfaceContentState();
}

class _MemoriesSurfaceContentState extends State<_MemoriesSurfaceContent> {
  late final _drag = MemoriesDragDriver(widget.controller);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return GestureDetector(
      onHorizontalDragStart: (_) => _drag.start(),
      onHorizontalDragUpdate: (d) => _drag.update(d, width, reduceMotion),
      onHorizontalDragEnd: (d) => _drag.end(d, reduceMotion),
      onHorizontalDragCancel: () => _drag.cancel(reduceMotion),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: _bgMain,
          border: Border(right: BorderSide(color: _border)),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 10, 6),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Memories',
                          style: TextStyle(
                              color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
                    ),
                    Semantics(
                      button: true,
                      label: 'Close',
                      child: IconButton(
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close, color: _fgSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              const Expanded(child: _MemoriesBody()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The surface's own content: the "Give me a memory" action and whatever it fetches.
/// Deliberately the only thing in v1 - see the muted "more coming" line for the future
/// entries (Map, Timeline, You Were There) this makes room for without building them.
class _MemoriesBody extends ConsumerStatefulWidget {
  const _MemoriesBody();

  @override
  ConsumerState<_MemoriesBody> createState() => _MemoriesBodyState();
}

class _MemoriesBodyState extends ConsumerState<_MemoriesBody> {
  Post? _memory;
  bool _loading = false;
  bool _fetched = false;
  bool _failed = false;

  Future<void> _fetch() async {
    final capable = ref.read(multiSessionProvider).memoriesCapableShownGroups;
    if (capable.isEmpty) {
      setState(() {
        _fetched = true;
        _failed = false;
        _memory = null;
      });
      return;
    }
    // Uniformly across every capable group in view, not just the current one - a multi-group
    // member's memories should draw from all of them, same as the feed does.
    //
    // Picked once, here, and reused after the await below rather than re-read from
    // provider state at that point: the shown-group selection can change while the request
    // is in flight (switching groups, a filter change), and the fetched post has to stay
    // tagged with the group it actually came from - not whatever happens to be selected by
    // the time the response lands. See memories_test.dart's mid-flight selection-change test.
    final group = capable[Random().nextInt(capable.length)];
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final post = await ref.read(apiForGroupProvider(group.id)).randomMemory();
      if (!mounted) return;
      setState(() {
        _memory = post?.withGroup(group.id);
        _loading = false;
        _fetched = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _fetched = true;
        _failed = true;
      });
    }
  }

  void _openMemory() {
    final m = _memory;
    if (m == null) return;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PostDetailScreen(postId: m.id, groupId: m.groupId)));
  }

  @override
  Widget build(BuildContext context) {
    if (!_fetched) return _idle(context);
    if (_failed) return _errorState(context);
    final m = _memory;
    return m == null ? _emptyState(context) : _loadedState(context, m);
  }

  Widget _idle(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 40, color: context.accent),
            const SizedBox(height: 16),
            const Text('Look back at something from your group\'s history.',
                textAlign: TextAlign.center, style: TextStyle(color: _fgSecondary, fontSize: 14)),
            const SizedBox(height: 20),
            PrimaryButton(
                label: 'Give me a memory', enabled: !_loading, busy: _loading, onTap: _fetch),
            const SizedBox(height: 14),
            const Text('More ways to look back - coming soon.',
                style: TextStyle(color: _fgMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history_outlined, size: 40, color: _fgMuted),
            const SizedBox(height: 16),
            const Text('Nothing to look back on yet.',
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              'Once your group has a couple of weeks of check-ins, memories will start showing up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _fgMuted, fontSize: 13),
            ),
            const SizedBox(height: 20),
            PrimaryButton(label: 'Check again', enabled: !_loading, busy: _loading, onTap: _fetch),
          ],
        ),
      ),
    );
  }

  Widget _errorState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 40, color: _fgMuted),
            const SizedBox(height: 16),
            const Text("Couldn't load a memory.",
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            PrimaryButton(label: 'Try again', enabled: !_loading, busy: _loading, onTap: _fetch),
          ],
        ),
      ),
    );
  }

  Widget _loadedState(BuildContext context, Post m) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      child: Column(
        children: [
          _MemoryCard(post: m, onTap: _openMemory),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Another', enabled: !_loading, busy: _loading, onTap: _fetch),
        ],
      ),
    );
  }
}

/// One fetched memory: the post's photo (falling back to its clip poster, then to its
/// caption when it carries no media), author, and how long ago it was - both an absolute
/// date and the founder's-brief relative phrasing (see [memoryAgeLabel]). Tapping opens the
/// original post.
class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.post, required this.onTap});

  final Post post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = post.imageMedia.isNotEmpty
        ? post.imageMedia.first
        : (post.videoMedia.isNotEmpty && post.videoMedia.first.hasPoster
            ? post.videoMedia.first
            : null);
    return Semantics(
      button: true,
      label: 'Open this memory',
      child: GestureDetector(
        onTap: onTap,
        // Without this, every descendant Text (the caption, the author name, the date) would
        // merge its own semantics up into this node, turning one announced action into a
        // wall of concatenated text. A screen reader should hear "Open this memory", not the
        // whole card read back to it - the card's content is already visible, tapping it is
        // the only thing this node needs to say.
        child: ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _bgSurface,
                border: Border.all(color: _border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (cover != null)
                    AspectRatio(
                      aspectRatio: cover.aspectRatio ?? 4 / 3,
                      child: AuthImage(
                        mediaId: cover.id,
                        groupId: post.groupId,
                        variant: cover.isVideo ? 'poster' : null,
                      ),
                    )
                  else if (post.body.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 22, 18, 4),
                      child: Text(post.body,
                          style: const TextStyle(color: _fgPrimary, fontSize: 17, height: 1.4)),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        UserAvatar(
                          name: post.authorName,
                          size: 34,
                          mediaId: post.authorPhotoId,
                          colorSeed: post.authorId,
                          groupId: post.groupId,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(post.authorName,
                                  style: const TextStyle(
                                      color: _fgPrimary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14)),
                              const SizedBox(height: 2),
                              Text(
                                '${DateFormat.yMMMMd().format(post.createdAt.toLocal())} · '
                                '${memoryAgeLabel(post.createdAt)}',
                                style: const TextStyle(color: _fgMuted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

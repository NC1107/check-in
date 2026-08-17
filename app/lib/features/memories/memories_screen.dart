import 'dart:async';
import 'dart:math';
import 'dart:ui' show lerpDouble;

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

/// The pill's opacity at rest: barely there, per the founder's "sortve hidden" brief - dim
/// enough to read as a seam in the bar rather than a control, until the periodic pulse (or,
/// under reduced motion, [kMemoriesPillReducedMotionOpacity]) says otherwise.
const kMemoriesPillRestOpacity = 0.12;

/// The pill's opacity at the peak of its periodic pulse - close to the old always-on grey
/// pill's own alpha, so the hint reads as a genuine affordance for the second or so it holds.
const kMemoriesPillPeakOpacity = 0.55;

/// The pill's constant opacity under [MediaQuery.disableAnimations]: nothing ever animates
/// there, so a reduced-motion viewer needs a steady, findable affordance rather than living
/// with the rest opacity's near-invisibility as the only state they'd ever see.
const kMemoriesPillReducedMotionOpacity = 0.34;

/// How often the pill pulses to remind an idle viewer it's there.
const kMemoriesPillPulseInterval = Duration(seconds: 30);
const kMemoriesPillPulseRise = Duration(milliseconds: 220);
const kMemoriesPillPulseHold = Duration(milliseconds: 560);
const kMemoriesPillPulseFall = Duration(milliseconds: 220);

/// One full pulse sweep: rise, then hold, then fall - see
/// [MemoriesPillPulseController._controller]'s own doc comment for why this is driven as one
/// continuous [AnimationController] sweep rather than three separately-scheduled steps.
/// `final`, not `const`: [Duration.+] isn't a const-evaluable operator.
final kMemoriesPillPulseTotalDuration =
    kMemoriesPillPulseRise + kMemoriesPillPulseHold + kMemoriesPillPulseFall;

/// The 4x26 grab handle's ambient pulse: drives [opacity] from [kMemoriesPillRestOpacity] up
/// to [kMemoriesPillPeakOpacity] and back for about a second, roughly every
/// [kMemoriesPillPulseInterval] - the founder's "mostly hidden, but says hello every 30s"
/// brief. A tiny state machine, not a widget, precisely so its scheduling rules (see
/// [setActive]) are unit-testable without pumping a widget tree - the same reasoning
/// [MemoriesDragDriver] documents for the drag.
///
/// Owns the [AnimationController] its caller constructs (vsync'd to the handle's own State)
/// but never the decision to animate at all: [setActive] is the single gate every condition
/// the founder's brief lists (Feed tab active, surface closed, app resumed, motion allowed)
/// goes through, so "must never run in the background" only has to be enforced in one place -
/// see MemoriesHandle's build() and lifecycle callbacks, the only callers.
///
/// One pulse is a single continuous [AnimationController.forward] sweep from 0 to 1 across
/// [_pulseDuration] (rise+hold+fall), not three separately-awaited animate/delay steps
/// chained together - deliberately: a `Future.delayed` created as a *side effect* of an
/// earlier animation's completion (mid-callback, not at the top of a fresh event) can land in
/// a timing noman's-land under flutter_test's own step-driven fake clock, where a
/// `tester.pump(duration)` that lands exactly on its target time doesn't reliably fire it
/// within that same call. A single sweep has one Ticker, started once, with [opacity] derived
/// purely from where in that sweep [_controller]'s own value currently sits - the same
/// well-trodden `tester.pump(duration)` mechanics every other AnimationController in this file
/// already relies on, no timer/future boundary for the fake clock to trip over.
class MemoriesPillPulseController {
  MemoriesPillPulseController(this._controller) {
    // Owned outright, regardless of whatever the caller constructed it with - forward(from:)
    // needs a duration to animate over, and pinning it here means a caller can never
    // accidentally desync it from the rise/hold/fall constants above by constructing the
    // controller with a different (or no) duration of its own.
    _controller.duration = kMemoriesPillPulseTotalDuration;
    _controller.addStatusListener(_onStatus);
  }

  /// Where the rise-to-hold and hold-to-fall handoffs fall within the sweep (as 0..1
  /// fractions of [kMemoriesPillPulseTotalDuration]) - [opacity] uses these to work out which
  /// phase [_controller]'s current value is in.
  static final double _riseEnd =
      kMemoriesPillPulseRise.inMicroseconds / kMemoriesPillPulseTotalDuration.inMicroseconds;
  static final double _holdEnd = (kMemoriesPillPulseRise + kMemoriesPillPulseHold).inMicroseconds /
      kMemoriesPillPulseTotalDuration.inMicroseconds;

  final AnimationController _controller;
  Timer? _timer;
  bool _active = false;
  bool _disposed = false;

  /// The pill's opacity right now: [kMemoriesPillRestOpacity] at rest (the sweep's start and
  /// end alike), ramping up to [kMemoriesPillPeakOpacity] across the rise fraction, holding
  /// there, then ramping back down across the fall fraction. Meant to be read inside an
  /// [AnimatedBuilder] listening to the wrapped controller.
  double get opacity {
    final t = _controller.value;
    double peaked; // 0 = at rest, 1 = fully peaked
    if (t <= _riseEnd) {
      peaked = _riseEnd <= 0 ? 1 : t / _riseEnd;
    } else if (t <= _holdEnd) {
      peaked = 1;
    } else {
      final fallSpan = 1 - _holdEnd;
      peaked = fallSpan <= 0 ? 0 : 1 - (t - _holdEnd) / fallSpan;
    }
    return lerpDouble(kMemoriesPillRestOpacity, kMemoriesPillPeakOpacity, peaked)!;
  }

  /// Whether a pulse is currently scheduled to fire. Exposed only for tests to assert the
  /// timer really was cancelled (not just that nothing threw) - see memories_test.dart's
  /// pulse controller group.
  @visibleForTesting
  bool get hasPendingTimer => _timer != null;

  /// The single gate on whether the pulse may run at all. A caller passes the AND of every
  /// condition that must hold; toggling it off (a tab switch, the surface opening, the app
  /// backgrounding, reduced motion) cuts an in-flight pulse off immediately rather than
  /// letting it finish its cycle - the whole point of a gate that "must stop" is that nothing
  /// keeps animating a moment after it should not be.
  void setActive(bool active) {
    if (_disposed || active == _active) return;
    _active = active;
    if (active) {
      _schedule();
    } else {
      _timer?.cancel();
      _timer = null;
      if (_controller.value != 0 || _controller.isAnimating) _controller.value = 0;
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(kMemoriesPillPulseInterval, _fire);
  }

  void _fire() {
    if (!_active || _disposed) return;
    _controller.forward(from: 0);
  }

  /// Reschedules the next pulse once a sweep runs all the way to its end - the single place
  /// that decides "settling back to rest reschedules", so a caller never has to chain off the
  /// forward() call itself (see the class doc comment for why that chaining was the bug).
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _active && !_disposed) _schedule();
  }

  /// Stops the timer and any in-flight animation cleanly. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _controller.removeStatusListener(_onStatus);
    _controller.stop();
  }
}

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
  const MemoriesHandle({super.key, required this.controller, required this.feedActive});

  final AnimationController controller;

  /// Whether the Feed tab is the one currently showing. home_shell.dart keeps the bottom bar
  /// (and so this handle) mounted on the You tab too, but the ambient pulse (see
  /// [MemoriesPillPulseController]) only ever runs here - pulsing on a tab the gesture's own
  /// screen isn't behind would draw an eye that has already left.
  final bool feedActive;

  @override
  ConsumerState<MemoriesHandle> createState() => _MemoriesHandleState();
}

class _MemoriesHandleState extends ConsumerState<MemoriesHandle>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final _drag = MemoriesDragDriver(widget.controller);
  late final _pulseController = AnimationController(vsync: this);
  late final _pulse = MemoriesPillPulseController(_pulseController);

  // Cached from the last build/lifecycle event, so callbacks that fire outside build (the
  // shared controller's own listener, an app-lifecycle change) can recompute the pulse's
  // one gating condition (see _recomputePulse) without a BuildContext of their own, and so
  // dispose() (which cannot safely call MediaQuery.of - the context is on its way out) still
  // knows whether to animate or snap when it settles a stranded drag. See dispose()'s own
  // comment.
  bool _reduceMotion = false;
  bool _capable = false;
  bool _appResumed = true;

  // Whether the shared Memories surface is anywhere above fully closed - mirrors
  // _HomeShellState's own _memoriesOpen and _MemoriesSurfaceState's _open, read off the same
  // controller. The pulse must not run while the surface covers the screen (see
  // _recomputePulse).
  late bool _surfaceOpen = widget.controller.value > 0;

  void _onControllerChanged() {
    final open = widget.controller.value > 0;
    if (open == _surfaceOpen) return;
    _surfaceOpen = open;
    _recomputePulse();
  }

  /// The pulse's single gate: every condition the founder's brief lists, ANDed together and
  /// handed to [MemoriesPillPulseController.setActive]. Called from build() with the latest
  /// values, and from every callback that can change one of them outside a build (the
  /// controller listener, app-lifecycle changes) using the cached fields above.
  void _recomputePulse() {
    _pulse
        .setActive(_capable && widget.feedActive && !_surfaceOpen && _appResumed && !_reduceMotion);
  }

  void _open(bool reduceMotion) {
    HapticFeedback.selectionClick();
    widget.controller.animateTo(1,
        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(MemoriesHandle old) {
    super.didUpdateWidget(old);
    if (old.feedActive != widget.feedActive) _recomputePulse();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never let the pulse keep ticking, or a timer keep waking the device, once the app is
    // backgrounded - a timer firing every 30s in the background is a battery bug, not a hint.
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _appResumed) return;
    _appResumed = resumed;
    _recomputePulse();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onControllerChanged);
    _pulse.dispose();
    _pulseController.dispose();
    // Belt and braces alongside _HomeShellState's own capability-drop guard (the
    // authoritative fix - see its doc comment): if this whole widget is ever removed from
    // the tree while a drag was in progress, rather than merely rebuilt to
    // SizedBox.shrink() (see build()'s own settle for that far more common case),
    // DragGestureRecognizer.dispose() does not fire onCancel, so nothing else would ever
    // settle the controller. A no-op when no drag was in progress - see
    // MemoriesDragDriver.cancel.
    _drag.cancel(_reduceMotion);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capable =
        ref.watch(multiSessionProvider.select((s) => s.memoriesCapableShownGroups.isNotEmpty));
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    _reduceMotion = reduceMotion;
    _capable = capable;
    _recomputePulse();
    // An overlay, not a Row child (see the class doc comment) - shrinking to nothing here
    // costs no layout, only removes the gesture surface and lets taps fall through to
    // whatever the handle was sitting on top of.
    if (!capable) {
      // Capability can drop mid-drag - a shown-group change, or a capability update
      // landing while a finger is down - and the GestureDetector subtree below is about to
      // be torn out from under that drag without ever getting an onCancel (see dispose()'s
      // comment: the same gap, just reached by a rebuild here rather than the whole widget
      // going away). Settle it first, so the controller never gets stranded between 0 and
      // 1 with nothing left mounted to finish the gesture.
      _drag.cancel(reduceMotion);
      return const SizedBox.shrink();
    }

    final width = MediaQuery.sizeOf(context).width;
    final accent = context.accent;
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
        // SafeArea-then-fixed-64-box mirrors BottomAppBar's own build exactly (see Flutter's
        // BottomAppBar, and home_shell.dart's Positioned doc comment right above where this
        // handle is placed) - it's what makes this box land at the same origin as the bar's
        // own content box on every device, regardless of its bottom safe inset, rather than
        // being centered against the bar's taller, safe-area-inflated total height.
        //
        // Getting the box right isn't enough on its own, though: a plain Center inside it
        // would still land the pill on the box's own geometric middle, which sits BELOW
        // where the Feed/You icon glyphs actually are - their Column packs icon+gap+label
        // together and centers that whole block, so the icon (the block's top part) ends up
        // above the block's own center once a label is added underneath. Repeating the exact
        // same icon-slot + gap + label-sized shape below (see _NavItem, and
        // kBottomNavIconSize/kBottomNavIconLabelGap/kBottomNavLabelStyle's shared doc
        // comment) reproduces that same displacement for the pill: Column's
        // mainAxisAlignment.center puts a first child's own center at
        // `boxCenter - (gap + labelHeight) / 2` regardless of that child's own height, so the
        // pill (26pt) lands exactly where a 23pt icon glyph would, without this having to
        // know or hardcode that offset as a magic pixel value.
        child: SafeArea(
          child: SizedBox(
            width: kMemoriesHandleWidth,
            height: 64,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, _) {
                      final opacity =
                          reduceMotion ? kMemoriesPillReducedMotionOpacity : _pulse.opacity;
                      // The visible pill stays exactly 4x26, centered in the wider tap
                      // target - only the grabbable area grows, never the look.
                      return Container(
                        key: const Key('memoriesPill'),
                        width: 4,
                        height: 26,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: opacity),
                          borderRadius: BorderRadius.circular(9999),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: kBottomNavIconLabelGap),
                  // Invisible - reserves exactly the label's own single-line height so this
                  // Column's shape matches _NavItem's and the pill above lands on the icons'
                  // own line. Never painted, never announced, and never findable by real
                  // copy: a plain "Memories" here would collide with find.text('Memories')
                  // elsewhere (the surface's own header title). maxLines: 1 matters in a way
                  // it doesn't for _NavItem's real "Feed"/"You" labels: those fit their Row's
                  // much wider Expanded slot on one line easily, but this handle is only
                  // kMemoriesHandleWidth (44) wide - without pinning this placeholder to one
                  // line it wraps across several, inflating the reserved height and
                  // overflowing the 64-tall box.
                  const Opacity(
                    opacity: 0,
                    child: ExcludeSemantics(
                      child: Text('MemoriesHandleLabelSpacer',
                          maxLines: 1, style: kBottomNavLabelStyle),
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

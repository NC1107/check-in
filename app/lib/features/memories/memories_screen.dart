import 'dart:async';
import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/auth_image.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail_screen.dart';

// Theme tokens (centralized in theme/tokens.dart).
const _bgMain = kBgMain;
const _bgSurface = kBgSurface;
const _bgSurfaceHover = kBgSurfaceHover;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;

/// The photo grid shared by an event's detail (_EventDetailView) and a month's detail
/// (_MonthDetailView) - one constant so the two can never quietly drift apart, per the
/// founder's brief that the month grid "reuse the event detail's grid exactly".
const _memoriesPhotoGridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 3,
  mainAxisSpacing: 8,
  crossAxisSpacing: 8,
);

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

/// Which top-level screen the hub is showing - see [MemoriesHubController].
enum HubScreen { hub, randomMemory, eventsList, timeline }

/// The Memories surface's own tiny internal navigation stack: hub -> ("Give me a memory"
/// or "You were there") -> (an events list entry may drill into one event's own detail).
/// Not a real [Navigator] - the stack here is never more than 2 deep and entirely known in
/// advance, so a plain [ChangeNotifier] holding "which screen" plus "which event, if any"
/// is simpler than standing up nested routing for it, while still giving MemoriesSurface's
/// own PopScope (see its doc comment) a single place to ask "is there anywhere left to step
/// back to before closing the whole surface".
class MemoriesHubController extends ChangeNotifier {
  HubScreen _screen = HubScreen.hub;
  Event? _selectedEvent;
  TimelineMonth? _selectedMonth;

  /// The explicit group pick from the surface's own group selector, or null when nothing
  /// has been picked yet (every reader falls back to [effectiveMemoriesGroupId]'s
  /// deterministic default in that case). Lives here, not in a Riverpod provider, because
  /// this controller is already the one thing every screen in the surface shares and
  /// already outlives individual screen visits for exactly this reason (see the class doc
  /// comment) - reusing it needs no new persistence machinery of its own.
  String? _selectedGroupId;

  HubScreen get screen => _screen;

  /// The group every Memories view currently reads from, once a selection has actually
  /// been made - see [effectiveMemoriesGroupId] for what callers use instead, which also
  /// covers the not-yet-selected case.
  String? get selectedGroupId => _selectedGroupId;

  /// Explicitly switches which group the whole surface reads from - the group selector's
  /// own onTap. A no-op when [id] is already selected, so it can never trigger a spurious
  /// refetch loop. Deliberately never called automatically with a computed default: see
  /// [effectiveMemoriesGroupId], which resolves the default fresh on every read instead of
  /// writing it back here, so a session change (a group hidden, added, or losing
  /// capability) before any real pick is made can never leave this pinned to a stale
  /// choice.
  void selectGroup(String id) {
    if (_selectedGroupId == id) return;
    _selectedGroupId = id;
    notifyListeners();
  }

  /// The event whose detail is showing, drilled into from the events list - null whenever
  /// the list itself (or any other screen) is what's showing.
  Event? get selectedEvent => _selectedEvent;

  /// The month whose detail is showing, drilled into from the timeline list - null whenever
  /// the list itself (or any other screen) is what's showing.
  TimelineMonth? get selectedMonth => _selectedMonth;

  void openRandomMemory() {
    _screen = HubScreen.randomMemory;
    notifyListeners();
  }

  void openEventsList() {
    _screen = HubScreen.eventsList;
    _selectedEvent = null;
    notifyListeners();
  }

  void openEventDetail(Event event) {
    _selectedEvent = event;
    notifyListeners();
  }

  void openTimeline() {
    _screen = HubScreen.timeline;
    _selectedMonth = null;
    notifyListeners();
  }

  void openTimelineMonth(TimelineMonth month) {
    _selectedMonth = month;
    notifyListeners();
  }

  /// Steps back exactly one level (event detail -> events list -> hub, month detail ->
  /// timeline list -> hub, or randomMemory -> hub) and returns true, or does nothing and
  /// returns false when already at the hub with nothing left to pop internally - the
  /// signal callers (Android back, the header's own back chevron) use to know whether they
  /// should instead close the whole surface.
  bool back() {
    if (_selectedEvent != null) {
      _selectedEvent = null;
      notifyListeners();
      return true;
    }
    if (_selectedMonth != null) {
      _selectedMonth = null;
      notifyListeners();
      return true;
    }
    if (_screen != HubScreen.hub) {
      _screen = HubScreen.hub;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Jumps straight back to the hub root - called whenever the surface itself closes, so
  /// reopening it later never shows a stale sub-screen from last time. Deliberately leaves
  /// [selectedGroupId] untouched: the surface stays mounted for the app's whole session
  /// (see home_shell.dart), so a group choice made on an earlier visit should still be
  /// there the next time the surface opens, not reset along with the navigation stack.
  void reset() {
    if (_screen == HubScreen.hub && _selectedEvent == null && _selectedMonth == null) return;
    _screen = HubScreen.hub;
    _selectedEvent = null;
    _selectedMonth = null;
    notifyListeners();
  }
}

/// The group every Memories view should actually read from right now: [picked] itself when
/// it still names a group both shown and capable of at least one Memories-surface feature,
/// otherwise a deterministic fallback - the feed's own single-group filter
/// ([MultiSession.soleShown]) when that filter narrows to exactly one such group, else the
/// first capable group in the app's existing shown-group ordering. Null only when [session]
/// has no capable group shown at all.
///
/// A pure function of its arguments, not a stateful resolution written back into
/// [MemoriesHubController] - every caller (the header selector, the hub's own per-entry
/// capability gate, and each of the three views) just calls this fresh off the live
/// [MultiSession], so a group being hidden, removed, or losing capability while the
/// surface sits open can never leave the surface pointing at nothing, and - the bug this
/// whole feature replaces - the result is never randomly chosen: the same inputs always
/// resolve to the same group.
String? effectiveMemoriesGroupId(MultiSession session, String? picked) {
  final capable = session.memoriesSurfaceCapableShownGroups;
  if (capable.isEmpty) return null;
  if (picked != null && capable.any((g) => g.id == picked)) return picked;
  final sole = session.soleShown;
  if (sole != null && capable.any((g) => g.id == sole.id)) return sole.id;
  return capable.first.id;
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

  // Owned here, not by the content widgets several layers down, because PopScope (right
  // below) is what Android back reaches first and it needs to be able to ask "is there
  // anywhere left to step back to internally" before deciding whether to close the whole
  // surface - see MemoriesHubController's own doc comment.
  final _hub = MemoriesHubController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onValueChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValueChanged);
    _hub.dispose();
    super.dispose();
  }

  void _onValueChanged() {
    final open = widget.controller.value > 0;
    if (open != _open) setState(() => _open = open);
    // Jump back to the hub root the instant the surface starts closing - not only once it
    // finishes - so a swipe-to-close that's cancelled partway through never leaves the
    // surface sitting at 0 with a stale sub-screen still showing underneath.
    if (!open) _hub.reset();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Step back one level within the hub first (event detail -> list -> hub, or
        // randomMemory -> hub) if there's anywhere left to go; only once the hub is
        // already at its root does back close the whole surface.
        if (_hub.back()) return;
        widget.onClose();
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
        child: _MemoriesSurfaceContent(
            controller: widget.controller, onClose: widget.onClose, hub: _hub),
      ),
    );
  }
}

class _MemoriesSurfaceContent extends ConsumerStatefulWidget {
  const _MemoriesSurfaceContent(
      {required this.controller, required this.onClose, required this.hub});

  final AnimationController controller;
  final VoidCallback onClose;
  final MemoriesHubController hub;

  @override
  ConsumerState<_MemoriesSurfaceContent> createState() => _MemoriesSurfaceContentState();
}

class _MemoriesSurfaceContentState extends ConsumerState<_MemoriesSurfaceContent> {
  late final _drag = MemoriesDragDriver(widget.controller);

  // Keyed per screen (and per selected event, month, or - for the three group-scoped
  // screens - selected group) so AnimatedSwitcher below treats each as a distinct child
  // and actually animates the swap, instead of diffing into the same widget type and
  // skipping the transition. Embedding the group id in the events/timeline keys is also
  // what makes switching the header's group selector refetch those two: a new key remounts
  // the view outright, which is a plain, correct refetch since both start from a loading
  // state on every visit anyway (see _EventsListViewState/_TimelineListViewState). The
  // random-memory screen deliberately does NOT remount this way - see _MemoriesBody's own
  // doc comment for why it instead reacts to a group change via didUpdateWidget.
  Widget _body(String? selectedGroupId) {
    final selectedEvent = widget.hub.selectedEvent;
    if (selectedEvent != null) {
      return _EventDetailView(
          key: ValueKey('event-${selectedEvent.postIds.join(',')}'),
          hub: widget.hub,
          event: selectedEvent);
    }
    final selectedMonth = widget.hub.selectedMonth;
    if (selectedMonth != null) {
      return _MonthDetailView(
          key: ValueKey('month-${selectedMonth.year}-${selectedMonth.month}'),
          hub: widget.hub,
          month: selectedMonth);
    }
    switch (widget.hub.screen) {
      case HubScreen.hub:
        return _MemoriesHubHome(key: const ValueKey('hub'), hub: widget.hub);
      case HubScreen.randomMemory:
        return _MemoriesBody(
            key: const ValueKey('random'), hub: widget.hub, groupId: selectedGroupId);
      case HubScreen.eventsList:
        return _EventsListView(
            key: ValueKey('events-$selectedGroupId'), hub: widget.hub, groupId: selectedGroupId);
      case HubScreen.timeline:
        return _TimelineListView(
            key: ValueKey('timeline-$selectedGroupId'), hub: widget.hub, groupId: selectedGroupId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final session = ref.watch(multiSessionProvider);
    final capableGroups = session.memoriesSurfaceCapableShownGroups;
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
          child: ListenableBuilder(
            listenable: widget.hub,
            builder: (context, _) {
              // A back chevron replaces nothing and sits alongside the close X - the two
              // are independent affordances (step back one level vs. leave entirely), not
              // a swap of one for the other. Absent at the hub root, where there's nowhere
              // left to step back to.
              final atRoot = widget.hub.screen == HubScreen.hub && widget.hub.selectedEvent == null;
              // The group selector only makes sense one level up from a specific fetched
              // event or month - drilling further in is already scoped to whatever group
              // that item came from, and switching there would have nothing coherent to do.
              final inDetail = widget.hub.selectedEvent != null || widget.hub.selectedMonth != null;
              final selectedGroupId = effectiveMemoriesGroupId(session, widget.hub.selectedGroupId);
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 10, 10, 6),
                    child: Row(
                      children: [
                        if (!atRoot)
                          Semantics(
                            button: true,
                            label: 'Back',
                            child: IconButton(
                              onPressed: widget.hub.back,
                              icon: const Icon(Icons.arrow_back, color: _fgSecondary),
                            ),
                          )
                        else
                          const SizedBox(width: 12),
                        const Expanded(
                          // Excluded from semantics: this is decorative chrome, and its
                          // own implicit "Memories" text label would otherwise merge up
                          // into the surface's own horizontal-drag GestureDetector (which
                          // contributes a scrollLeft/scrollRight semantics node of its
                          // own) - colliding with the handle's OWN explicit
                          // Semantics(label: 'Memories') button and making
                          // find.bySemanticsLabel('Memories') ambiguous.
                          child: ExcludeSemantics(
                            child: Text('Memories',
                                style: TextStyle(
                                    color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
                          ),
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
                  // Only shown with something real to choose between - a member of exactly
                  // one capable group (by far the common case) sees nothing here at all,
                  // same as before this feature existed.
                  if (capableGroups.length > 1 && !inDetail)
                    Padding(
                      padding: const EdgeInsets.only(left: 14, right: 14, bottom: 10),
                      child: _MemoriesGroupSelector(
                        groups: capableGroups,
                        selectedGroupId: selectedGroupId,
                        onSelect: widget.hub.selectGroup,
                      ),
                    ),
                  Expanded(
                    // A lightweight fade + slide so stepping between hub/list/detail feels
                    // like the rest of the app's pushes, without dragging in a full
                    // Navigator (the surface already has its own back-stack in
                    // MemoriesHubController).
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero)
                              .animate(animation),
                          child: child,
                        ),
                      ),
                      child: _body(selectedGroupId),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One group in the Memories surface's own header selector (see
/// [_MemoriesGroupSelector]) - the same pill idiom the feed's own filter sheet uses for its
/// GROUPS row (a color dot, a border pill, a checkmark and accent fill once selected), so
/// switching groups here reads as the app's existing multi-group affordance rather than a
/// new one invented for this screen.
class _MemoriesGroupPill extends StatelessWidget {
  const _MemoriesGroupPill({required this.account, required this.selected, required this.onTap});

  final ServerAccount account;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: account.displayName,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? context.accent : Colors.transparent,
            border: Border.all(color: selected ? context.accent : _border),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: account.displayColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              if (selected) ...[
                Icon(Icons.check, size: 13, color: context.onAccent),
                const SizedBox(width: 4),
              ],
              Text(account.displayName,
                  style: TextStyle(
                      color: selected ? context.onAccent : _fgSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Memories surface header's own group switcher: one [_MemoriesGroupPill] per capable
/// shown group, horizontally scrollable so it never wraps the header taller. Governs all
/// three of the surface's views at once (see [effectiveMemoriesGroupId]) - picking a group
/// here is the one place that selection changes.
class _MemoriesGroupSelector extends StatelessWidget {
  const _MemoriesGroupSelector({
    required this.groups,
    required this.selectedGroupId,
    required this.onSelect,
  });

  final List<ServerAccount> groups;
  final String? selectedGroupId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: groups.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => _MemoriesGroupPill(
          account: groups[i],
          selected: groups[i].id == selectedGroupId,
          onTap: () => onSelect(groups[i].id),
        ),
      ),
    );
  }
}

/// The hub root: "Random check-in", "Group trips" and "Month by month", each gated on the
/// SELECTED group's own server capability (see [effectiveMemoriesGroupId]) - a group whose
/// server has some subset of the three only ever offers those, and switching the header's
/// group selector changes which subset shows here exactly as it changes what the other two
/// views fetch.
class _MemoriesHubHome extends ConsumerWidget {
  const _MemoriesHubHome({super.key, required this.hub});

  final MemoriesHubController hub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(multiSessionProvider);
    final selected = session.byId(effectiveMemoriesGroupId(session, hub.selectedGroupId));
    final memoriesOn = selected?.memoriesCapable ?? false;
    final eventsOn = selected?.eventsCapable ?? false;
    final timelineOn = selected?.timelineCapable ?? false;
    final entries = [
      if (memoriesOn)
        _HubEntry(
          icon: Icons.auto_awesome_outlined,
          title: 'Random check-in',
          subtitle: "Look back at something from your group's history.",
          onTap: hub.openRandomMemory,
        ),
      if (eventsOn)
        _HubEntry(
          icon: Icons.map_outlined,
          title: 'Group trips',
          subtitle: 'Trips and nights out your group shared.',
          onTap: hub.openEventsList,
        ),
      if (timelineOn)
        _HubEntry(
          icon: Icons.calendar_month_outlined,
          title: 'Month by month',
          subtitle: "The group's life, one month at a time.",
          onTap: hub.openTimeline,
        ),
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              entries[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One hub entry: an icon, a title, a one-line subtitle, and a chevron - the app's
/// existing card idiom (14 corner radius, surface fill, a border) rather than a new shape
/// invented for this screen.
class _HubEntry extends StatelessWidget {
  const _HubEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _bgSurface,
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(icon, size: 26, color: context.accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(height: 3),
                      Text(subtitle, style: const TextStyle(color: _fgMuted, fontSize: 12)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: _fgMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Random check-in" screen: the existing single-random-post action and whatever it
/// fetches, scoped to [groupId] (see [effectiveMemoriesGroupId]). Pushed onto the hub
/// rather than shown at its root - see [MemoriesHubController].
class _MemoriesBody extends ConsumerStatefulWidget {
  const _MemoriesBody({super.key, required this.hub, required this.groupId});

  final MemoriesHubController hub;
  final String? groupId;

  @override
  ConsumerState<_MemoriesBody> createState() => _MemoriesBodyState();
}

class _MemoriesBodyState extends ConsumerState<_MemoriesBody> {
  Post? _memory;
  bool _loading = false;
  bool _fetched = false;
  bool _failed = false;
  bool _unsupported = false;

  /// Bumped by every call to [_fetch]; a call captures its own value and only ever applies
  /// its result if it's still the current one when the response lands. Without this, a
  /// group switch mid-request couldn't tell "this response belongs to the group now
  /// selected" from "this response belongs to a group that's since been abandoned" - a late
  /// arrival from the abandoned request would still call setState and paint its content
  /// under a header pill that by then names a different group entirely.
  int _fetchSeq = 0;

  @override
  void didUpdateWidget(_MemoriesBody old) {
    super.didUpdateWidget(old);
    if (old.groupId == widget.groupId) return;
    // Nothing has ever been fetched for this screen, so there is nothing on screen that
    // could disagree with the pill - stays idle, exactly like a fresh mount. It is a
    // deliberate one-tap action, not something that should fire a request just because the
    // selector moved.
    if (!_loading && !_fetched) return;
    // A fetch already started for the OLD group - in flight, or already landed. Reset to
    // the same pre-fetch state a fresh mount starts from, THEN fetch again: the screen goes
    // straight from "old group's content" to idle-while-loading and never sits on the old
    // group's card, error, or unsupported message under the newly selected group's pill -
    // not even for a single frame. Bumping _fetchSeq inside _fetch() below also means a
    // still-in-flight response from the old group is discarded on arrival rather than
    // painting over whatever this triggers next. See memories_test.dart's "switch during
    // the first fetch" regression test.
    setState(() {
      _memory = null;
      _loading = false;
      _fetched = false;
      _failed = false;
      _unsupported = false;
    });
    _fetch();
  }

  Future<void> _fetch() async {
    final seq = ++_fetchSeq;
    final groupId = widget.groupId;
    // Reads the current group's ServerAccount up front and reuses it after the await below
    // rather than re-resolving it once the response lands: the selection can change while
    // the request is in flight, and the fetched post has to stay tagged with the group it
    // actually came from - not whatever happens to be selected by the time the response
    // lands. See memories_test.dart's mid-flight selection-change test.
    final account = groupId == null ? null : ref.read(multiSessionProvider).byId(groupId);
    if (account == null) {
      setState(() {
        _fetched = true;
        _failed = false;
        _unsupported = false;
        _memory = null;
      });
      return;
    }
    if (!account.memoriesCapable) {
      setState(() {
        _fetched = true;
        _failed = false;
        _unsupported = true;
        _memory = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _unsupported = false;
    });
    try {
      final post = await ref.read(apiForGroupProvider(account.id)).randomMemory();
      if (!mounted || seq != _fetchSeq) return;
      setState(() {
        _memory = post?.withGroup(account.id);
        _loading = false;
        _fetched = true;
      });
    } catch (_) {
      if (!mounted || seq != _fetchSeq) return;
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
    if (_unsupported) return _unsupportedState(context);
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
                label: 'Random check-in', enabled: !_loading, busy: _loading, onTap: _fetch),
          ],
        ),
      ),
    );
  }

  Widget _unsupportedState(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 40, color: _fgMuted),
            SizedBox(height: 16),
            Text("This group doesn't support Random check-in.",
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text(
              'Its server needs an update before this can pull anything up from its history.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _fgMuted, fontSize: 13),
            ),
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

/// "Aug 10" for a single day, "Aug 10 - Aug 16" (or "Aug 10 - Sep 2, 2027" across a year
/// boundary) for a range - the compact date line an event card and its detail screen both
/// show under the place name.
String eventDateRangeLabel(Event event, {DateTime? now}) {
  final start = event.startDate.toLocal();
  final end = event.endDate.toLocal();
  if (start.year == end.year && start.month == end.month && start.day == end.day) {
    return DateFormat.yMMMd().format(start);
  }
  if (start.year == end.year) {
    return '${DateFormat.MMMd().format(start)} - ${DateFormat.yMMMd().format(end)}';
  }
  return '${DateFormat.yMMMd().format(start)} - ${DateFormat.yMMMd().format(end)}';
}

/// The events list: every detected trip/gathering for [groupId] (see
/// [effectiveMemoriesGroupId]), newest first exactly as the server already ranks them. Keyed
/// by that group id at the call site (see _MemoriesSurfaceContentState._body), so switching
/// the header's group selector remounts this fresh rather than leaving stale events up.
class _EventsListView extends ConsumerStatefulWidget {
  const _EventsListView({super.key, required this.hub, required this.groupId});

  final MemoriesHubController hub;
  final String? groupId;

  @override
  ConsumerState<_EventsListView> createState() => _EventsListViewState();
}

class _EventsListViewState extends ConsumerState<_EventsListView> {
  List<Event>? _events;
  bool _loading = true;
  bool _failed = false;
  bool _unsupported = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final groupId = widget.groupId;
    final account = groupId == null ? null : ref.read(multiSessionProvider).byId(groupId);
    if (account == null) {
      setState(() {
        _events = const [];
        _loading = false;
        _failed = false;
        _unsupported = false;
      });
      return;
    }
    if (!account.eventsCapable) {
      setState(() {
        _events = const [];
        _loading = false;
        _failed = false;
        _unsupported = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _unsupported = false;
    });
    try {
      final events = await ref.read(apiForGroupProvider(account.id)).events();
      if (!mounted) return;
      setState(() {
        _events = [for (final e in events) e.withGroup(account.id)];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Center(child: CircularProgressIndicator(color: context.accent));
    if (_failed) return _errorState(context);
    if (_unsupported) return _unsupportedState(context);
    final events = _events ?? const [];
    if (events.isEmpty) return _emptyState(context);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
      itemCount: events.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _EventCard(
        event: events[i],
        onTap: () => widget.hub.openEventDetail(events[i]),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 40, color: _fgMuted),
            SizedBox(height: 16),
            Text('No trips or gatherings yet.',
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text(
              "Once your group checks in together from the same place, they'll show up here.",
              textAlign: TextAlign.center,
              style: TextStyle(color: _fgMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unsupportedState(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 40, color: _fgMuted),
            SizedBox(height: 16),
            Text("This group doesn't support Group trips.",
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text(
              'Its server needs an update before trips and gatherings can show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _fgMuted, fontSize: 13),
            ),
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
            const Text("Couldn't load your group's events.",
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            PrimaryButton(label: 'Try again', enabled: !_loading, busy: _loading, onTap: _fetch),
          ],
        ),
      ),
    );
  }
}

/// One event: a cover photo (or a plain trip/gathering icon when nothing in it has a
/// photo), the place, the date range, who was there, and a photo count - everything the
/// founder's brief asked the card to carry. Tapping opens the event's own photos.
class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, required this.onTap});

  final Event event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${event.place}, ${event.isTrip ? 'trip' : 'gathering'}',
      child: GestureDetector(
        onTap: onTap,
        // See _MemoryCard's identical guard: without this every descendant Text merges its
        // own semantics into this node, turning one announced action into a wall of text.
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
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: event.coverMediaId != null
                        ? AuthImage(mediaId: event.coverMediaId!, groupId: event.groupId)
                        : ColoredBox(
                            color: _bgSurfaceHover,
                            child: Icon(
                              event.isTrip ? Icons.flight_takeoff_outlined : Icons.groups_outlined,
                              size: 32,
                              color: _fgMuted,
                            ),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PillBadge(
                          icon:
                              event.isTrip ? Icons.flight_takeoff_outlined : Icons.groups_outlined,
                          label: event.isTrip ? 'TRIP' : 'GATHERING',
                          accent: context.accentPalette,
                        ),
                        const SizedBox(height: 8),
                        Text(event.place,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 15)),
                        const SizedBox(height: 3),
                        Text(eventDateRangeLabel(event),
                            style: const TextStyle(color: _fgMuted, fontSize: 12)),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            _AvatarStack(participants: event.participants, groupId: event.groupId),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(event.participantsLabel,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: _fgSecondary, fontSize: 12)),
                            ),
                            const Icon(Icons.photo_outlined, size: 14, color: _fgMuted),
                            const SizedBox(width: 3),
                            Text('${event.photoCount}',
                                style: const TextStyle(color: _fgMuted, fontSize: 12)),
                          ],
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

/// A small overlapping row of participant avatars, capped at [_max] - "4 friends" reads
/// the exact count via [Event.participantsLabel] right next to it, so the stack itself
/// only needs to suggest "a few people", not enumerate everyone.
class _AvatarStack extends StatelessWidget {
  const _AvatarStack({required this.participants, this.groupId});

  final List<EventParticipant> participants;
  final String? groupId;

  static const _max = 4;
  static const _size = 24.0;
  static const _overlap = 14.0;

  @override
  Widget build(BuildContext context) {
    final shown = participants.take(_max).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: _size + (shown.length - 1) * _overlap,
      height: _size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * _overlap,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _bgSurface, width: 2),
                ),
                child: UserAvatar(
                  name: shown[i].name,
                  size: _size,
                  mediaId: shown[i].photoId,
                  colorSeed: shown[i].id,
                  groupId: groupId,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One event's own photos: fetches the full post for each of [Event.postIds] (the events
/// endpoint only ever returns ids and a summary - see the server's db.Event) and flattens
/// every post's images into one grid. A photo's tile remembers which post it came from, so
/// tapping it opens the same full-screen viewer and "go to post" route a normal feed
/// carousel does - scoped to that one post's own photos, not the whole event's, exactly
/// like a feed card's own carousel already behaves (see post_card.dart).
class _EventDetailView extends ConsumerStatefulWidget {
  const _EventDetailView({super.key, required this.hub, required this.event});

  final MemoriesHubController hub;
  final Event event;

  @override
  ConsumerState<_EventDetailView> createState() => _EventDetailViewState();
}

class _EventDetailViewState extends ConsumerState<_EventDetailView> {
  List<Post>? _posts;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Post?> _tryGetPost(ApiClient api, int id) async {
    try {
      return await api.getPost(id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final groupId = widget.event.groupId;
    if (groupId == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    final api = ref.read(apiForGroupProvider(groupId));
    final posts = await Future.wait([
      for (final id in widget.event.postIds) _tryGetPost(api, id),
    ]);
    if (!mounted) return;
    setState(() {
      _posts = [
        for (final p in posts)
          if (p != null) p.withGroup(groupId)
      ];
      _loading = false;
    });
  }

  /// Every image on every fetched post, in event order, paired with the post it belongs
  /// to - the flat list the grid renders and each tile's tap target reads its post/media
  /// from.
  List<({Post post, PostMedia media})> get _photos => [
        for (final p in _posts ?? const <Post>[])
          for (final m in p.imageMedia) (post: p, media: m),
      ];

  @override
  Widget build(BuildContext context) {
    if (_loading) return Center(child: CircularProgressIndicator(color: context.accent));
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 40, color: _fgMuted),
              const SizedBox(height: 16),
              const Text("Couldn't load this event.",
                  style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 20),
              PrimaryButton(label: 'Try again', enabled: true, onTap: _load),
            ],
          ),
        ),
      );
    }
    final photos = _photos;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _header(context)),
        if (photos.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child:
                    Text('No photos in this one.', style: TextStyle(color: _fgMuted, fontSize: 13)),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            sliver: SliverGrid(
              gridDelegate: _memoriesPhotoGridDelegate,
              delegate: SliverChildBuilderDelegate(
                (context, i) => _PhotoTile(post: photos[i].post, media: photos[i].media),
                childCount: photos.length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final event = widget.event;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(event.place,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 4),
          Text(eventDateRangeLabel(event), style: const TextStyle(color: _fgMuted, fontSize: 13)),
          const SizedBox(height: 10),
          Row(
            children: [
              _AvatarStack(participants: event.participants, groupId: event.groupId),
              const SizedBox(width: 8),
              Expanded(
                child: Text(event.participantsLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _fgSecondary, fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One tile in an event's photo grid - see _EventDetailView's own doc comment for why
/// tapping it opens the viewer scoped to just this photo's own post.
class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.post, required this.media});

  final Post post;
  final PostMedia media;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open photo',
      child: GestureDetector(
        onTap: () =>
            PhotoViewerScreen.open(context, media: [media], groupId: post.groupId, postId: post.id),
        child: ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AuthImage(mediaId: media.id, groupId: post.groupId),
          ),
        ),
      ),
    );
  }
}

/// The timeline list: the group's history bucketed into calendar months, newest first, for
/// [groupId] (see [effectiveMemoriesGroupId]). Keyed by that group id at the call site (see
/// _MemoriesSurfaceContentState._body), so switching the header's group selector remounts
/// this fresh rather than leaving stale months up.
class _TimelineListView extends ConsumerStatefulWidget {
  const _TimelineListView({super.key, required this.hub, required this.groupId});

  final MemoriesHubController hub;
  final String? groupId;

  @override
  ConsumerState<_TimelineListView> createState() => _TimelineListViewState();
}

class _TimelineListViewState extends ConsumerState<_TimelineListView> {
  List<TimelineMonth>? _months;
  bool _loading = true;
  bool _failed = false;
  bool _unsupported = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final groupId = widget.groupId;
    final account = groupId == null ? null : ref.read(multiSessionProvider).byId(groupId);
    if (account == null) {
      setState(() {
        _months = const [];
        _loading = false;
        _failed = false;
        _unsupported = false;
      });
      return;
    }
    if (!account.timelineCapable) {
      setState(() {
        _months = const [];
        _loading = false;
        _failed = false;
        _unsupported = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _unsupported = false;
    });
    try {
      final months = await ref.read(apiForGroupProvider(account.id)).timeline();
      if (!mounted) return;
      setState(() {
        _months = [for (final m in months) m.withGroup(account.id)];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Center(child: CircularProgressIndicator(color: context.accent));
    if (_failed) return _errorState(context);
    if (_unsupported) return _unsupportedState(context);
    final months = _months ?? const [];
    if (months.isEmpty) return _emptyState(context);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
      itemCount: months.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _MonthCard(
        month: months[i],
        onTap: () => widget.hub.openTimelineMonth(months[i]),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_month_outlined, size: 40, color: _fgMuted),
            SizedBox(height: 16),
            Text('No history yet.',
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text(
              "Once your group starts checking in, their months will show up here.",
              textAlign: TextAlign.center,
              style: TextStyle(color: _fgMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unsupportedState(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_month_outlined, size: 40, color: _fgMuted),
            SizedBox(height: 16),
            Text("This group doesn't support Month by month.",
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text(
              'Its server needs an update before its history can browse here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _fgMuted, fontSize: 13),
            ),
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
            const Text("Couldn't load your group's months.",
                style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            PrimaryButton(label: 'Try again', enabled: !_loading, busy: _loading, onTap: _fetch),
          ],
        ),
      ),
    );
  }
}

/// One month: its cover strip, the month and year, and its numbers - check-ins, photos,
/// places, and how many people posted. Tapping it opens that month's own photo grid (see
/// _MonthDetailView).
class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.month, required this.onTap});

  final TimelineMonth month;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: month.label,
      child: GestureDetector(
        onTap: onTap,
        // See _EventCard's identical guard: without this every descendant Text merges its
        // own semantics into this node, turning one announced action into a wall of text.
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
                  _CoverStrip(month: month),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(month.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 15)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 14,
                          runSpacing: 6,
                          children: [
                            _StatItem(
                                icon: Icons.check_circle_outline,
                                value: month.postCount,
                                suffix: month.postCount == 1 ? 'check-in' : 'check-ins'),
                            if (month.photoCount > 0)
                              _StatItem(
                                  icon: Icons.photo_outlined,
                                  value: month.photoCount,
                                  suffix: month.photoCount == 1 ? 'photo' : 'photos'),
                            if (month.placeCount > 0)
                              _StatItem(
                                  icon: Icons.place_outlined,
                                  value: month.placeCount,
                                  suffix: month.placeCount == 1 ? 'place' : 'places'),
                            _StatItem(
                                icon: Icons.groups_outlined,
                                value: month.posterCount,
                                suffix: month.posterCount == 1 ? 'person' : 'people'),
                          ],
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

/// One "N label" stat, e.g. "12 check-ins" - a small icon plus text pair a month card's
/// stat row repeats for each number it shows.
class _StatItem extends StatelessWidget {
  const _StatItem({required this.icon, required this.value, required this.suffix});

  final IconData icon;
  final int value;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: _fgMuted),
        const SizedBox(width: 3),
        Text('$value $suffix', style: const TextStyle(color: _fgMuted, fontSize: 12)),
      ],
    );
  }
}

/// A month card's cover art: a thin strip of its best photos side by side, or a plain
/// placeholder when the month carries no cover at all (an all-text month). Each tile is
/// its own [AuthImage], which already degrades a since-deleted cover to a broken-image
/// icon on its own (see auth_image.dart's errorWidget) rather than failing the whole card -
/// exactly the "missing media must degrade, not break the strip" contract this needs.
class _CoverStrip extends StatelessWidget {
  const _CoverStrip({required this.month});

  final TimelineMonth month;

  @override
  Widget build(BuildContext context) {
    final ids = month.coverMediaIds;
    if (ids.isEmpty) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: _bgSurfaceHover,
          child: Center(
            child: Icon(Icons.photo_outlined, size: 32, color: _fgMuted),
          ),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Row(
        children: [
          for (var i = 0; i < ids.length; i++) ...[
            if (i > 0) const SizedBox(width: 1),
            Expanded(child: AuthImage(mediaId: ids[i], groupId: month.groupId)),
          ],
        ],
      ),
    );
  }
}

/// One month's own photos: fetches that month's posts directly - unlike _EventDetailView,
/// which only ever has post ids to re-fetch one by one, the timeline month route already
/// returns full feed-shaped posts in one call - and flattens them into the exact same photo
/// grid _EventDetailView uses (see _memoriesPhotoGridDelegate): same columns, spacing, and
/// tile radius. Tapping a photo opens the same full-screen viewer and "go to post" route.
class _MonthDetailView extends ConsumerStatefulWidget {
  const _MonthDetailView({super.key, required this.hub, required this.month});

  final MemoriesHubController hub;
  final TimelineMonth month;

  @override
  ConsumerState<_MonthDetailView> createState() => _MonthDetailViewState();
}

class _MonthDetailViewState extends ConsumerState<_MonthDetailView> {
  List<Post>? _posts;

  /// Whether the server capped this month's posts (see ApiClient.timelineMonth) - the
  /// header's own check-in count is built from _posts.length plus this flag, never from
  /// widget.month.postCount: that field is an unbounded aggregate from the month LIST route
  /// and can legitimately exceed what this screen actually fetched and can show.
  bool _hasMore = false;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final groupId = widget.month.groupId;
    if (groupId == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    try {
      final result = await ref
          .read(apiForGroupProvider(groupId))
          .timelineMonth(widget.month.year, widget.month.month);
      if (!mounted) return;
      setState(() {
        _posts = [for (final p in result.posts) p.withGroup(groupId)];
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// Every image on every fetched post, in the server's own (newest-first) order, paired
  /// with the post it belongs to - the same flattening _EventDetailView.photos does.
  List<({Post post, PostMedia media})> get _photos => [
        for (final p in _posts ?? const <Post>[])
          for (final m in p.imageMedia) (post: p, media: m),
      ];

  @override
  Widget build(BuildContext context) {
    if (_loading) return Center(child: CircularProgressIndicator(color: context.accent));
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 40, color: _fgMuted),
              const SizedBox(height: 16),
              const Text("Couldn't load this month.",
                  style: TextStyle(color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 20),
              PrimaryButton(label: 'Try again', enabled: true, onTap: _load),
            ],
          ),
        ),
      );
    }
    final photos = _photos;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _header(context)),
        if (photos.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child:
                    Text('No photos this month.', style: TextStyle(color: _fgMuted, fontSize: 13)),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            sliver: SliverGrid(
              gridDelegate: _memoriesPhotoGridDelegate,
              delegate: SliverChildBuilderDelegate(
                (context, i) => _PhotoTile(post: photos[i].post, media: photos[i].media),
                childCount: photos.length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final month = widget.month;
    // Sized off what was actually fetched (see _load's own doc comment on _hasMore), so
    // this line can never claim more check-ins than the grid below it actually holds. A
    // "+" marks a month the server capped, rather than silently rounding it down to a
    // plain (and then quietly wrong) number.
    final shown = _posts?.length ?? 0;
    final countLabel = _hasMore ? '$shown+' : '$shown';
    final checkinNoun = (!_hasMore && shown == 1) ? 'check-in' : 'check-ins';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(month.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 4),
          Text(
            '$countLabel $checkinNoun · '
            '${month.posterCount} ${month.posterCount == 1 ? 'person' : 'people'}',
            style: const TextStyle(color: _fgMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

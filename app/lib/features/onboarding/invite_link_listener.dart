import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import 'auth_screen.dart';
import 'invite_links.dart';

/// Root navigator, so an invite link can push the add-group flow from outside the tree.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// The group already signed in on this device that an invite for [server] would re-add, or
/// null for a genuinely new server. Matches on the derived group id (the host), the same key
/// the session stores groups under, so a link and an existing group line up regardless of
/// path or trailing slashes.
///
/// Only signed-in groups count. A group you still have but are signed out of falls through
/// to the connect screen on purpose: re-login, not a "you're already in" dead end, is the
/// way back in there.
ServerAccount? existingGroupForInvite(MultiSession session, String server) {
  final id = MultiSessionController.groupIdFor(server);
  for (final g in session.signedIn) {
    if (g.id == id) return g;
  }
  return null;
}

/// Delivers platform deep links ([inviteServerFromUri]) into [pendingInviteServerProvider].
///
/// Must be mounted inside `ProviderScope` but OUTSIDE `MaterialApp`. Route observers are
/// consulted in registration order and a parent registers before its child, so from above
/// `MaterialApp` this sees the link first. From below, `WidgetsApp` gets it instead and
/// pushes it as a named route against an app that has no routes table, which is an
/// unhandled-route assertion rather than a join.
class InviteLinkListener extends ConsumerStatefulWidget {
  const InviteLinkListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<InviteLinkListener> createState() => _InviteLinkListenerState();
}

class _InviteLinkListenerState extends ConsumerState<InviteLinkListener>
    with WidgetsBindingObserver {
  /// Whether we already pushed the add-group flow, so a second link (or the same one tapped
  /// twice) tops up the prefill instead of stacking another connect screen.
  bool _addGroupOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final uri = routeInformation.uri;
    final server = inviteServerFromUri(uri);
    if (server != null) {
      _receive(server);
      return true;
    }
    // Consume anything else on our own scheme too. Declining hands it to `WidgetsApp` as a
    // route push (see the class comment) and, on iOS, has the engine re-open the URL
    // through the system.
    return uri.scheme == 'checkin';
  }

  /// Parks the invite for [AuthScreen] to prefill from, and opens that screen itself only
  /// when nothing else is going to.
  void _receive(String server) {
    // The platform hop that gets us here is only observable on a real device, and a link
    // that silently does nothing looks the same as one the OS never delivered. This is what
    // tells those two apart during a device test.
    debugPrint('[CHECKIN] invite link: $server');
    ref.read(pendingInviteServerProvider.notifier).park(server);

    // Every other state already routes through AuthScreen, which takes the parked invite as
    // its prefill: the EULA gate that App Review signed off on comes first, the blank frame
    // while sessions restore resolves into it, and a signed-out app is already showing it.
    // Pushing over any of those would be worse than waiting.
    final session = ref.read(multiSessionProvider);
    if (!ref.read(termsProvider) || !session.restored || !session.anySignedIn) return;
    if (_addGroupOpen) return;

    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;

    // A link for a group already connected here would otherwise drop the user into the
    // connect flow for a group they already have. Tell them instead, and drop the parked
    // invite so it can't prefill the next manual connect.
    final existing = existingGroupForInvite(session, server);
    if (existing != null) {
      ref.read(pendingInviteServerProvider.notifier).consume();
      _showAlreadyJoined(navigator, existing.displayName);
      return;
    }

    _addGroupOpen = true;
    navigator
        .push(MaterialPageRoute<void>(builder: (_) => AuthScreen(initialServer: server)))
        .whenComplete(() => _addGroupOpen = false);
  }

  void _showAlreadyJoined(NavigatorState navigator, String groupName) {
    showDialog<void>(
      context: navigator.context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: Text("You're already in $groupName",
            style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700)),
        content: const Text(
          'This group is already connected on this device, so there is nothing to join.',
          style: TextStyle(color: kFgSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Seeds [pendingInviteServerProvider] from the route the app was launched with, for a
/// `ProviderScope` created before the first frame.
///
/// Android hands a cold-start deep link over as [PlatformDispatcher.defaultRouteName]
/// rather than as a route push, so [InviteLinkListener] never sees it. Applying it as an
/// override is synchronous, which is what keeps it ahead of `AuthScreen.initState` instead
/// of racing it.
List<Override> inviteLinkOverrides({String? initialRoute}) {
  final route = initialRoute ?? PlatformDispatcher.instance.defaultRouteName;
  final uri = Uri.tryParse(route);
  final server = uri == null ? null : inviteServerFromUri(uri);
  if (server == null) return const [];
  return [pendingInviteServerProvider.overrideWith(() => PendingInviteServer(initial: server))];
}

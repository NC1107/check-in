import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/feed/home_shell.dart';
import 'features/onboarding/auth_screen.dart';
import 'features/onboarding/invite_links.dart';
import 'features/onboarding/terms_screen.dart';
import 'notifications/push_messaging.dart';
import 'state/app_state.dart';
import 'theme/tokens.dart';

/// Root navigator, so invite links can push the add-group flow from outside the tree.
final rootNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  // Ensure plugins (secure storage, prefs) are ready before providers spin up, and route
  // all uncaught errors to one place so a stray exception can't silently kill startup.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Lock the app to portrait — no landscape or upside-down.
      await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('[CHECKIN] FlutterError: ${details.exceptionAsString()}');
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('[CHECKIN] $error');
        return true;
      };
      await _initFirebase();
      runApp(const ProviderScope(child: CheckInApp()));
    },
    (error, stack) => debugPrint('[CHECKIN] uncaught: $error'),
  );
}

/// Bring up Firebase + push on mobile only. The native google-services config is read
/// automatically. Best-effort: if Firebase isn't configured for a build (e.g. web), the
/// app still starts — it just won't receive cloud push.
Future<void> _initFirebase() async {
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS)) {
    return;
  }
  try {
    await Firebase.initializeApp();
    await initPush();
  } catch (e) {
    debugPrint('[CHECKIN] firebase init skipped: $e');
  }
}

class CheckInApp extends ConsumerStatefulWidget {
  const CheckInApp({super.key});

  @override
  ConsumerState<CheckInApp> createState() => _CheckInAppState();
}

class _CheckInAppState extends ConsumerState<CheckInApp> {
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _initInviteLinks();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  /// Invite links (see invite_links.dart) open the add-group flow with the group's
  /// server prefilled. Best-effort: without link support the paste-based flow remains.
  Future<void> _initInviteLinks() async {
    if (kIsWeb) return;
    try {
      final appLinks = AppLinks();
      final initial = await appLinks.getInitialLink();
      if (initial != null) _handleLink(initial);
      _linkSub = appLinks.uriLinkStream.listen(_handleLink);
    } catch (_) {}
  }

  void _handleLink(Uri uri) {
    final server = inviteServerFromUri(uri);
    if (server == null) return;
    // Stash it so the root auth screen prefills even when we can't push (cold start,
    // EULA still pending).
    ref.read(pendingInviteServerProvider.notifier).state = server;
    if (!ref.read(termsProvider)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => AuthScreen(initialServer: server)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(multiSessionProvider);
    final accent = ref.watch(accentProvider);
    final termsAccepted = ref.watch(termsProvider);

    // Show the EULA once before login/signup (Guideline 1.2). After acceptance the
    // user lands on the normal auth flow — or straight into the app when any connected
    // group still has a session. A blank frame covers the brief prefs restore so the
    // auth screen doesn't flash on every warm start.
    final Widget home = !termsAccepted
        ? const TermsScreen()
        : !session.restored
            ? const Scaffold(body: SizedBox.shrink())
            : (session.anySignedIn ? const HomeShell() : const AuthScreen());

    return MaterialApp(
      title: 'Check-In',
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: accent.base,
          onPrimary: accent.onAccent,
          secondary: accent.hover,
          surface: kBgSurface,
          onSurface: kFgPrimary,
          outline: kBorder,
          error: kLike,
        ),
        scaffoldBackgroundColor: kBgMain,
        cardColor: kBgSurface,
        dividerColor: kBorder,
        useMaterial3: true,
        extensions: [accent],
      ),
      home: home,
    );
  }
}

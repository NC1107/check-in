import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/feed/home_shell.dart';
import 'features/onboarding/auth_screen.dart';
import 'state/app_state.dart';
import 'theme/tokens.dart';

void main() {
  // Ensure plugins (secure storage, prefs) are ready before providers spin up, and route
  // all uncaught errors to one place so a stray exception can't silently kill startup.
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('[CHECKIN] FlutterError: ${details.exceptionAsString()}');
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('[CHECKIN] $error');
        return true;
      };
      runApp(const ProviderScope(child: CheckInApp()));
    },
    (error, stack) => debugPrint('[CHECKIN] uncaught: $error'),
  );
}

class CheckInApp extends ConsumerWidget {
  const CheckInApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);

    // AuthScreen now owns server-connect + login/signup as one flow, so anyone not yet
    // logged in lands there (it pre-fills the last server used).
    final Widget home = session.isLoggedIn ? const HomeShell() : const AuthScreen();

    return MaterialApp(
      title: 'Check-In',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          onPrimary: kOnAccent,
          secondary: kAccentHover,
          surface: kBgSurface,
          onSurface: kFgPrimary,
          outline: kBorder,
          error: kLike,
        ),
        scaffoldBackgroundColor: kBgMain,
        cardColor: kBgSurface,
        dividerColor: kBorder,
        useMaterial3: true,
      ),
      home: home,
    );
  }
}

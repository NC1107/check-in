import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/feed/home_shell.dart';
import 'features/onboarding/auth_screen.dart';
import 'features/onboarding/connect_screen.dart';
import 'state/app_state.dart';

// Key used to persist the most recent crash report across launches.
const kLastCrashKey = '_last_crash';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Catch synchronous Flutter framework errors (e.g. build-phase exceptions).
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _saveCrash('FlutterError: ${details.exceptionAsString()}\n${details.stack}');
  };

  // Catch errors on the root isolate that escape the zone.
  PlatformDispatcher.instance.onError = (error, stack) {
    _saveCrash('PlatformDispatcher: $error\n$stack');
    return true;
  };

  runZonedGuarded(
    () => runApp(const ProviderScope(child: CheckInApp())),
    (error, stack) => _saveCrash('Zone: $error\n$stack'),
  );
}

Future<void> _saveCrash(String message) async {
  debugPrint('[CHECKIN-CRASH] $message');
  try {
    final prefs = await SharedPreferences.getInstance();
    final ts = DateTime.now().toIso8601String();
    await prefs.setString(kLastCrashKey, '[$ts]\n$message');
  } catch (_) {}
}

class CheckInApp extends ConsumerWidget {
  const CheckInApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);

    Widget home;
    if (!session.hasServer) {
      home = const ConnectScreen();
    } else if (!session.isLoggedIn) {
      home = const AuthScreen();
    } else {
      home = const HomeShell();
    }

    return MaterialApp(
      title: 'Check-In',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4C6EF5)),
        useMaterial3: true,
      ),
      home: home,
    );
  }
}

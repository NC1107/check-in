import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/feed/home_shell.dart';
import 'features/onboarding/connect_screen.dart';
import 'features/onboarding/auth_screen.dart';
import 'state/app_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: CheckInApp()));
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

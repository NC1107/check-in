import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/birthday_notifier.dart';
import '../../state/app_state.dart';
import '../admin/admin_screen.dart';
import '../post/create_post_screen.dart';
import '../profile/profile_screen.dart';
import 'feed_screen.dart';

/// HomeShell hosts the main tabs once a user is logged in and schedules birthday
/// notifications when opened.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Sync friends' birthdays and (re)schedule local notifications on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduleBirthdayNotifications(ref.read(apiProvider));
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider).user;
    final isAdmin = me?.isAdmin ?? false;

    final pages = <Widget>[
      const FeedScreen(),
      if (me != null) ProfileScreen(userId: me.id, isSelf: true),
      if (isAdmin) const AdminScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      floatingActionButton: _index == 0
          ? FloatingActionButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CreatePostScreen()),
              ),
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Feed'),
          const NavigationDestination(icon: Icon(Icons.person_outline), label: 'Me'),
          if (isAdmin)
            const NavigationDestination(
                icon: Icon(Icons.admin_panel_settings_outlined), label: 'Admin'),
        ],
      ),
    );
  }
}

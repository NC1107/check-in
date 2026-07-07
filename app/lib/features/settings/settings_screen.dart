import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/push_messaging.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../profile/edit_profile_sheet.dart';
import 'edit_group_screen.dart';
import 'notification_settings_screen.dart';

/// SettingsScreen gathers the account actions behind the profile's gear icon: edit
/// profile, appearance, notifications, member management (hosts), log out, and delete
/// account. Everything account-shaped is scoped to one group ([groupId], null = the
/// current group) - identity is per-server.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, this.groupId});

  final String? groupId;

  Future<void> _editProfile(BuildContext context, WidgetRef ref) async {
    final account = ref.read(contentAccountProvider(groupId));
    final user = account?.user;
    if (user == null) return;
    final updated = await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => EditProfileSheet(user: user, groupId: groupId),
    );
    if (updated != null && account != null) {
      ref.read(multiSessionProvider.notifier).updateUser(account.id, updated);
    }
  }

  Future<void> _logOut(BuildContext context, WidgetRef ref) async {
    final api = ref.read(contentApiProvider(groupId));
    final account = ref.read(contentAccountProvider(groupId));
    final nav = Navigator.of(context);
    // Drop this group's push registration while the session is still valid; the
    // other groups keep theirs.
    await clearDeviceToken(api);
    try {
      await api.logout();
    } catch (_) {}
    if (account != null) {
      await ref.read(multiSessionProvider.notifier).signOutGroup(account.id);
    }
    // Back to the shell (or the auth screen when this was the last session).
    nav.popUntil((route) => route.isFirst);
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: const Text('Delete your account?',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700)),
        content: const Text(
          'This permanently deletes your account, all your check-ins, comments, and profile. '
          'This cannot be undone.',
          style: TextStyle(color: kFgSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: kFgSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kLike, foregroundColor: Colors.white),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    HapticFeedback.mediumImpact();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final account = ref.read(contentAccountProvider(groupId));
      await ref.read(contentApiProvider(groupId)).deleteAccount();
      // The account is gone on that server; drop the group from this device. Other
      // groups (separate servers, separate accounts) are untouched.
      if (account != null) {
        await ref.read(multiSessionProvider.notifier).removeGroup(account.id);
      }
      nav.popUntil((route) => route.isFirst);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not delete account. Try again.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(contentAccountProvider(groupId));
    final session = ref.watch(multiSessionProvider);
    final groupCount = session.groups.length;
    final title =
        groupCount > 1 && account != null ? 'Settings · ${account.displayName}' : 'Settings';

    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: Text(title,
            style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: ListView(
        children: [
          // Appearance (the accent color) lives inside Edit profile now.
          _tile(
            icon: Icons.edit_outlined,
            label: 'Edit profile',
            onTap: () => _editProfile(context, ref),
          ),
          _tile(
            icon: Icons.notifications_none_rounded,
            label: 'Notifications',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
            ),
          ),
          // Everything group-shaped - name/color/members for hosts, local nickname for
          // everyone, adding a group, leaving a group - lives in the Edit groups submenu.
          if (session.signedIn.isNotEmpty)
            _tile(
              icon: Icons.tune,
              label: 'Edit groups',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EditGroupsScreen()),
              ),
            ),
          const Divider(color: kBorder, height: 24),
          _tile(
            icon: Icons.logout,
            label: 'Log out',
            onTap: () => _logOut(context, ref),
          ),
          _tile(
            icon: Icons.delete_forever_outlined,
            label: 'Delete account',
            danger: true,
            onTap: () => _deleteAccount(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? kLike : kFgPrimary;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, size: 22, color: danger ? kLike : kFgSecondary),
      title: Text(label, style: TextStyle(color: color, fontSize: 15)),
      trailing: danger ? null : const Icon(Icons.chevron_right, size: 18, color: kFgMuted),
    );
  }
}

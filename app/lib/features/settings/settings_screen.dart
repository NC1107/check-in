import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/push_messaging.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../profile/edit_profile_sheet.dart';
import 'appearance_screen.dart';
import 'edit_group_screen.dart';
import 'notification_settings_screen.dart';

/// SettingsScreen gathers the account actions behind the profile's gear icon: edit
/// profile, appearance, notifications, member management (hosts), log out, and delete
/// account. Everything account-shaped is scoped to one group ([groupId], null = the
/// current group) — identity is per-server.
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

  /// Sets a per-device nickname for the group (local only, the server's name is
  /// untouched). Admins rename the group for everyone via Edit group instead.
  Future<void> _renameGroup(BuildContext context, WidgetRef ref) async {
    final account = ref.read(contentAccountProvider(groupId));
    if (account == null) return;
    final ctrl = TextEditingController(text: account.displayName);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: const Text('Group name',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 40,
              style: const TextStyle(color: kFgPrimary),
              decoration: InputDecoration(
                hintText: account.serverName,
                hintStyle: const TextStyle(color: kFgMuted),
              ),
            ),
            Text(
              'Only on this device. Leave empty to use the group\'s own name '
              '("${account.serverName}").',
              style: const TextStyle(color: kFgMuted, fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: kFgSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !context.mounted) return;
    final v = ctrl.text.trim();
    // Typing the server's own name back counts as "no nickname" so the display keeps
    // following any future server-side rename.
    await ref
        .read(multiSessionProvider.notifier)
        .renameGroup(account.id, v == account.serverName ? null : v);
  }

  /// Opens the group editor. A host of several groups picks which one first - every
  /// group they admin is editable from here, no switching required.
  Future<void> _editGroup(BuildContext context, WidgetRef ref, List<ServerAccount> admin) async {
    if (admin.length == 1) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => EditGroupScreen(groupId: admin.first.id)));
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kBgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Edit which group?',
                    style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
              ),
            ),
            for (final g in admin)
              ListTile(
                leading: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(color: g.displayColor, shape: BoxShape.circle),
                ),
                title: Text(g.displayName, style: const TextStyle(color: kFgPrimary, fontSize: 15)),
                trailing: const Icon(Icons.chevron_right, size: 18, color: kFgMuted),
                onTap: () => Navigator.of(context).pop(g.id),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditGroupScreen(groupId: picked)));
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
    final user = account?.user;
    final session = ref.watch(multiSessionProvider);
    final groupCount = session.groups.length;
    // Every group this user hosts is editable from here (name/color/members), so a
    // multi-group admin never has to switch the feed to another group first.
    final adminGroups = [
      for (final g in session.signedIn)
        if (g.user?.isAdmin ?? false) g
    ];
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
          _tile(
            icon: Icons.edit_outlined,
            label: 'Edit profile',
            onTap: () => _editProfile(context, ref),
          ),
          _tile(
            icon: Icons.palette_outlined,
            label: 'Appearance',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AppearanceScreen()),
            ),
          ),
          _tile(
            icon: Icons.notifications_none_rounded,
            label: 'Notifications',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
            ),
          ),
          // Admins edit the group itself (name/color/members) in one place; everyone
          // else can still nickname the group locally.
          if (!(user?.isAdmin ?? false))
            _tile(
              icon: Icons.drive_file_rename_outline,
              label: 'Group name',
              onTap: () => _renameGroup(context, ref),
            ),
          if (adminGroups.isNotEmpty)
            _tile(
              icon: Icons.tune,
              label: 'Edit group',
              onTap: () => _editGroup(context, ref, adminGroups),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/push_messaging.dart';
import '../../state/app_state.dart';
import '../../theme/group_color.dart';
import '../../theme/tokens.dart';
import '../admin/admin_screen.dart';
import '../profile/edit_profile_sheet.dart';
import 'appearance_screen.dart';
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

  /// Renames the group. An admin renames it server-side (everyone sees the new name);
  /// anyone else sets a per-device nickname (local only, the server's name is untouched).
  Future<void> _renameGroup(BuildContext context, WidgetRef ref) async {
    final account = ref.read(contentAccountProvider(groupId));
    if (account == null) return;
    final isAdmin = account.user?.isAdmin ?? false;
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
              isAdmin
                  ? 'This renames the group for everyone.'
                  : 'Only on this device. Leave empty to use the group\'s own name '
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
    final notifier = ref.read(multiSessionProvider.notifier);
    if (isAdmin) {
      // An empty field would blank the group's name for everyone — keep the current one.
      if (v.isEmpty) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ref.read(contentApiProvider(groupId)).renameServer(v);
        await notifier.applyServerName(account.id, v);
      } catch (_) {
        messenger
            .showSnackBar(const SnackBar(content: Text('Could not rename the group. Try again.')));
      }
    } else {
      // Typing the server's own name back counts as "no nickname" so the display keeps
      // following any future server-side rename.
      await notifier.renameGroup(account.id, v == account.serverName ? null : v);
    }
  }

  /// Admin-only: set the group's color for everyone from the shared group palette. Color
  /// is a server-owned identity cue (unlike the per-device nickname), so only hosts see
  /// this. Picking "Automatic" clears it back to the deterministic color.
  Future<void> _pickGroupColor(BuildContext context, WidgetRef ref) async {
    final account = ref.read(contentAccountProvider(groupId));
    if (account == null) return;
    final current = account.color ?? '';
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: const Text('Group color',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Shown to everyone so groups are told apart in the combined feed.',
                style: TextStyle(color: kFgMuted, fontSize: 12.5, height: 1.4)),
            const SizedBox(height: 18),
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [
                for (final g in kGroupColors)
                  _ColorSwatch(
                    color: g.color,
                    selected: current == g.id,
                    onTap: () => Navigator.pop(ctx, g.id),
                  ),
                _ColorSwatch(
                  color: null,
                  selected: current.isEmpty,
                  onTap: () => Navigator.pop(ctx, ''),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(contentApiProvider(groupId)).setGroupColor(picked);
      await ref.read(multiSessionProvider.notifier).applyServerColor(account.id, picked);
    } catch (_) {
      messenger
          .showSnackBar(const SnackBar(content: Text('Could not update the color. Try again.')));
    }
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
    final groupCount = ref.watch(multiSessionProvider.select((s) => s.groups.length));
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
          _tile(
            icon: Icons.drive_file_rename_outline,
            label: 'Group name',
            onTap: () => _renameGroup(context, ref),
          ),
          if (user?.isAdmin ?? false)
            _tile(
              icon: Icons.palette_outlined,
              label: 'Group color',
              onTap: () => _pickGroupColor(context, ref),
            ),
          if (user?.isAdmin ?? false)
            _tile(
              icon: Icons.group_outlined,
              label: 'Members',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminScreen()),
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

/// One swatch in the admin group-color picker. A null [color] is the "Automatic" option
/// (clears the admin color back to the deterministic one).
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color, required this.selected, required this.onTap});

  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: color == null ? 'Automatic color' : 'Group color',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color ?? kBgMain,
            shape: BoxShape.circle,
            border: Border.all(color: selected ? kFgPrimary : kBorder, width: selected ? 3 : 1),
          ),
          child: color == null
              ? const Icon(Icons.format_color_reset_outlined, size: 20, color: kFgMuted)
              : (selected ? const Icon(Icons.check, size: 22, color: Colors.black) : null),
        ),
      ),
    );
  }
}

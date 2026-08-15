import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/push_messaging.dart';
import '../../state/app_state.dart';
import '../../theme/group_color.dart';
import '../../theme/tokens.dart';
import '../admin/admin_screen.dart';
import '../onboarding/auth_screen.dart';

/// The one home for group management, reached from Settings > Edit groups: every
/// signed-in group (hosts marked), each opening its editor ([EditGroupScreen]), plus
/// adding a group. No switching the feed first.
class EditGroupsScreen extends ConsumerWidget {
  const EditGroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(multiSessionProvider);
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: const Text('Edit groups',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: ListView(
        children: [
          for (final g in session.signedIn)
            ListTile(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => EditGroupScreen(groupId: g.id)),
              ),
              leading: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(color: g.displayColor, shape: BoxShape.circle),
              ),
              title: Text(g.displayName, style: const TextStyle(color: kFgPrimary, fontSize: 15)),
              subtitle: Text((g.user?.isAdmin ?? false) ? 'Host · ${g.id}' : g.id,
                  style: const TextStyle(color: kFgMuted, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right, size: 18, color: kFgMuted),
            ),
          // Signed-out groups get plain rows rather than the editor: renaming, recolouring
          // and member management all need a live token. Without them the only affordance
          // anywhere was the feed filter's "sign back in", a dead end for anyone the host
          // removed.
          for (final g in session.signedOut)
            ListTile(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => AuthScreen(initialServer: g.baseUrl)),
              ),
              leading: const Icon(Icons.lock_outline, size: 18, color: kFgMuted),
              title: Text(g.displayName,
                  style: const TextStyle(color: kFgSecondary, fontSize: 15)),
              subtitle: Text('Signed out · ${g.id}',
                  style: const TextStyle(color: kFgMuted, fontSize: 12)),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18, color: kFgMuted),
                tooltip: 'Remove from this device',
                onPressed: () => _forget(context, ref, g),
              ),
            ),
          const Divider(color: kBorder, height: 24),
          ListTile(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AuthScreen()),
            ),
            leading: const Icon(Icons.add, size: 22, color: kFgSecondary),
            title: const Text('Add group', style: TextStyle(color: kFgPrimary, fontSize: 15)),
            trailing: const Icon(Icons.chevron_right, size: 18, color: kFgMuted),
          ),
        ],
      ),
    );
  }

  /// Drops a signed-out group from this device. Distinct from leaving: there is no token
  /// left to log out with, so this never calls the group's server - which is the point,
  /// since the reason it is signed out may be that the server rejected or forgot us.
  Future<void> _forget(BuildContext context, WidgetRef ref, ServerAccount g) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: Text('Remove ${g.displayName}?',
            style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700)),
        content: const Text(
          'This only forgets the group on this device, so it stops showing in your feed '
          'filter. If your account there still exists you can add the group again anytime.',
          style: TextStyle(color: kFgSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: kFgSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    HapticFeedback.mediumImpact();
    await ref.read(multiSessionProvider.notifier).removeGroup(g.id);
  }
}

/// One group's editor, reached from Settings > Edit groups. Hosts manage the shared
/// settings (name, color, members); everyone else can nickname the group locally; and
/// anyone can leave it. Scoped to [groupId] directly, so a multi-group user manages any
/// group from here without switching the feed over first.
class EditGroupScreen extends ConsumerWidget {
  const EditGroupScreen({super.key, required this.groupId});

  final String groupId;

  /// Sets a per-device nickname (local only, the server's name is untouched). The
  /// non-host counterpart of the server-side rename.
  Future<void> _nickname(BuildContext context, WidgetRef ref) async {
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

  /// Leaves this group: removes it from the device (token + entry). The account and
  /// check-ins stay on the group's server - recoverable by signing back in, unlike
  /// Delete account.
  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final session = ref.read(multiSessionProvider);
    final account = session.byId(groupId);
    if (account == null) return;
    final lastGroup = session.signedIn.length <= 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: Text('Leave ${account.displayName}?',
            style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700)),
        content: Text(
          'This removes the group from this device. Your account and check-ins stay on the '
          "group's server, and you can sign back in anytime. To erase them permanently, use "
          'Delete account instead.'
          '${lastGroup ? "\n\nThis is your only group - you'll land back on the connect screen." : ''}',
          style: const TextStyle(color: kFgSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: kFgSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    HapticFeedback.mediumImpact();
    final nav = Navigator.of(context);
    // Best effort: stop this group's push and invalidate its session server-side. The
    // local removal happens regardless (the server may simply be unreachable).
    final api = ref.read(apiForGroupProvider(groupId));
    try {
      await clearDeviceToken(api);
    } catch (_) {}
    try {
      await api.logout();
    } catch (_) {}
    await ref.read(multiSessionProvider.notifier).removeGroup(groupId);
    nav.popUntil((route) => route.isFirst);
  }

  /// Renames the group server-side: every member sees the new name.
  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final account = ref.read(contentAccountProvider(groupId));
    if (account == null) return;
    final ctrl = TextEditingController(text: account.serverName);
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
            const Text('This renames the group for everyone.',
                style: TextStyle(color: kFgMuted, fontSize: 12.5, height: 1.4)),
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
    // An empty field would blank the group's name for everyone - keep the current one.
    if (v.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(contentApiProvider(groupId)).renameServer(v);
      await ref.read(multiSessionProvider.notifier).applyServerName(account.id, v);
    } catch (_) {
      messenger
          .showSnackBar(const SnackBar(content: Text('Could not rename the group. Try again.')));
    }
  }

  /// Sets the group's color for everyone from the shared group palette. Picking
  /// "Automatic" clears it back to the deterministic color.
  Future<void> _pickColor(BuildContext context, WidgetRef ref) async {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(contentAccountProvider(groupId));
    final name = account?.displayName ?? 'Group';
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(color: account?.displayColor, shape: BoxShape.circle),
            ),
            Flexible(
              child: Text('Edit $name',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
            ),
          ],
        ),
      ),
      body: ListView(
        children: [
          // Hosts change the shared settings; everyone else nicknames the group locally.
          if (account?.user?.isAdmin ?? false) ...[
            _tile(
              icon: Icons.drive_file_rename_outline,
              label: 'Group name',
              onTap: () => _rename(context, ref),
            ),
            _tile(
              icon: Icons.palette_outlined,
              label: 'Group color',
              onTap: () => _pickColor(context, ref),
            ),
            _tile(
              icon: Icons.group_outlined,
              label: 'Members',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => AdminScreen(groupId: groupId)),
              ),
            ),
          ] else
            _tile(
              icon: Icons.drive_file_rename_outline,
              label: 'Group name',
              onTap: () => _nickname(context, ref),
            ),
          const Divider(color: kBorder, height: 24),
          _tile(
            icon: Icons.group_off_outlined,
            label: 'Leave group',
            onTap: () => _leave(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _tile({required IconData icon, required String label, required VoidCallback onTap}) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, size: 22, color: kFgSecondary),
      title: Text(label, style: const TextStyle(color: kFgPrimary, fontSize: 15)),
      trailing: const Icon(Icons.chevron_right, size: 18, color: kFgMuted),
    );
  }
}

/// One swatch in the group-color picker. A null [color] is the "Automatic" option
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

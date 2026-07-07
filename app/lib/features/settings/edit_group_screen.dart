import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/group_color.dart';
import '../../theme/tokens.dart';
import '../admin/admin_screen.dart';

/// Admin editor for one group's shared settings - name, color, and members - reached from
/// Settings > Edit group. It is scoped to [groupId] directly, so a host who admins several
/// groups edits any of them from here without switching the feed over first.
class EditGroupScreen extends ConsumerWidget {
  const EditGroupScreen({super.key, required this.groupId});

  final String groupId;

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

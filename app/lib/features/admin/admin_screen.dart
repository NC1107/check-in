import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/user_avatar.dart';
import 'contacts_picker_screen.dart';

/// AdminScreen lets the admin build the signup allowlist (invite list) — from contacts or
/// typed numbers — see who's been invited and who has joined, and manage members.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  late Future<List<Invite>> _invites;
  late Future<List<User>> _users;
  final _phonesCtrl = TextEditingController();
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _invites = ref.read(apiProvider).adminListAllowed();
    _users = ref.read(apiProvider).adminListUsers();
  }

  @override
  void dispose() {
    _phonesCtrl.dispose();
    super.dispose();
  }

  void _refreshInvites() =>
      setState(() => _invites = ref.read(apiProvider).adminListAllowed());
  void _refreshUsers() =>
      setState(() => _users = ref.read(apiProvider).adminListUsers());

  /// Parse the free-text field into phone numbers separated by newlines, commas, or
  /// semicolons.
  List<String> _parsePhones() => _phonesCtrl.text
      .split(RegExp(r'[\n,;]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _uploadTyped() async {
    final phones = _parsePhones();
    if (phones.isEmpty) {
      _snack('Enter at least one phone number.');
      return;
    }
    await _upload(phones);
    if (mounted) _phonesCtrl.clear();
  }

  Future<void> _importFromContacts() async {
    final phones = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => const ContactsPickerScreen()),
    );
    if (phones == null || phones.isEmpty) return;
    await _upload(phones);
  }

  /// Shared upload path for both contacts import and manual entry. Reports how many were
  /// newly added vs. already invited, then refreshes the list so the admin sees them.
  Future<void> _upload(List<String> phones) async {
    setState(() => _uploading = true);
    try {
      final r = await ref.read(apiProvider).uploadContacts(phones);
      final added = r['added'] as int? ?? 0;
      final valid = r['valid'] as int? ?? 0;
      final dupes = valid - added;
      _snack(added == 0
          ? 'No new numbers — those ${valid == 1 ? 'one was' : '$valid were'} already invited.'
          : 'Added $added to the invite list${dupes > 0 ? ' ($dupes already invited)' : ''}.');
      _refreshInvites();
    } catch (e) {
      _snack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _removeInvite(Invite inv) async {
    try {
      await ref.read(apiProvider).adminRemoveInvite(inv.phone);
      _refreshInvites();
    } catch (_) {
      _snack('Could not remove that number.');
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: kBgSurfaceHover));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: const Text('Members & invites',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _addCard(),
          const SizedBox(height: 22),
          _invitesSection(),
          const SizedBox(height: 22),
          _membersSection(),
        ],
      ),
    );
  }

  // ---- add to invite list ----

  Widget _addCard() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Invite people',
              style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          const Text(
            'Each number becomes its own invite — they just enter it to sign up. Add from '
            'your contacts or type numbers in.',
            style: TextStyle(color: kFgSecondary, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: _uploading ? 'Adding…' : 'Pick from contacts',
            enabled: !_uploading,
            busy: _uploading,
            onTap: _importFromContacts,
          ),
          const SizedBox(height: 16),
          const FieldLabel('Or add numbers manually'),
          AppTextField(
            controller: _phonesCtrl,
            hint: '+1 (415) 555-0148\n+1 (415) 555-0199',
            keyboardType: TextInputType.phone,
            minLines: 2,
            maxLines: 5,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _uploading ? null : _uploadTyped,
              icon: const Icon(Icons.person_add_alt, size: 18, color: kFgPrimary),
              label: const Text('Add typed numbers', style: TextStyle(color: kFgPrimary)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: kBorder),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- invite list ----

  Widget _invitesSection() {
    return FutureBuilder<List<Invite>>(
      future: _invites,
      builder: (context, snap) {
        final invites = snap.data ?? [];
        final pending = invites.where((i) => !i.used).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader('Invite list', snap.connectionState == ConnectionState.waiting
                ? null
                : '$pending pending · ${invites.length - pending} joined'),
            const SizedBox(height: 10),
            if (snap.connectionState == ConnectionState.waiting)
              _loading()
            else if (snap.hasError)
              _hint('Could not load the invite list.')
            else if (invites.isEmpty)
              _hint('No one invited yet. Add numbers above and they’ll appear here.')
            else
              _panel(
                padded: false,
                child: Column(
                  children: [
                    for (var i = 0; i < invites.length; i++) ...[
                      if (i > 0) const Divider(height: 1, color: kBorder),
                      _inviteRow(invites[i]),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _inviteRow(Invite inv) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      child: Row(
        children: [
          Icon(inv.used ? Icons.check_circle : Icons.schedule,
              size: 20, color: inv.used ? kSuccess : kFgMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(inv.phone,
                style: const TextStyle(color: kFgPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
          ),
          _statusChip(inv.used),
          if (!inv.used)
            IconButton(
              icon: const Icon(Icons.close, size: 18, color: kFgMuted),
              tooltip: 'Remove invite',
              onPressed: () => _removeInvite(inv),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _statusChip(bool used) {
    final color = used ? kSuccess : kFgSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: used ? kAccentLight : kBgSurfaceHover,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(used ? 'Joined' : 'Pending',
          style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 11)),
    );
  }

  // ---- members ----

  Widget _membersSection() {
    return FutureBuilder<List<User>>(
      future: _users,
      builder: (context, snap) {
        final users = snap.data ?? [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader('Members',
                snap.connectionState == ConnectionState.waiting ? null : '${users.length}'),
            const SizedBox(height: 10),
            if (snap.connectionState == ConnectionState.waiting)
              _loading()
            else
              _panel(
                padded: false,
                child: Column(
                  children: [
                    for (var i = 0; i < users.length; i++) ...[
                      if (i > 0) const Divider(height: 1, color: kBorder),
                      _memberRow(users[i]),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _memberRow(User u) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          UserAvatar(name: u.name, mediaId: u.profileMediaId, size: 40, colorSeed: u.id),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(u.name,
                    style: const TextStyle(
                        color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
                Text(u.isAdmin ? 'Host' : u.phone,
                    style: const TextStyle(color: kFgMuted, fontSize: 12)),
              ],
            ),
          ),
          if (!u.isAdmin)
            IconButton(
              icon: const Icon(Icons.person_remove_outlined, size: 20, color: kFgMuted),
              tooltip: 'Remove member',
              onPressed: () => _confirmRevoke(u),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmRevoke(User u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kBgSurface,
        title: Text('Remove ${u.name}?', style: const TextStyle(color: kFgPrimary)),
        content: const Text('They will no longer be able to log in.',
            style: TextStyle(color: kFgSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: kFgSecondary))),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: kLike, foregroundColor: Colors.white),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(apiProvider).revokeUser(u.id);
      _refreshUsers();
    }
  }

  // ---- shared bits ----

  Widget _sectionHeader(String title, String? trailing) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title,
              style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 15)),
          if (trailing != null)
            Text(trailing, style: const TextStyle(color: kFgMuted, fontSize: 12)),
        ],
      );

  Widget _panel({required Widget child, bool padded = true}) => Container(
        decoration: BoxDecoration(
          color: kBgSurface,
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.hardEdge,
        padding: padded ? const EdgeInsets.all(16) : EdgeInsets.zero,
        child: child,
      );

  Widget _hint(String text) => _panel(
        child: Text(text, style: const TextStyle(color: kFgMuted, fontSize: 13, height: 1.5)),
      );

  Widget _loading() => const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator(color: kAccent)),
      );
}

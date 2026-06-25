import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../widgets/auth_image.dart';
import 'contacts_picker_screen.dart';

/// AdminScreen lets the admin build the signup allowlist by entering phone numbers
/// and manage existing members.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  late Future<List<User>> _users;
  final _phonesCtrl = TextEditingController();
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _users = ref.read(apiProvider).adminListUsers();
  }

  @override
  void dispose() {
    _phonesCtrl.dispose();
    super.dispose();
  }

  void _refreshUsers() {
    setState(() => _users = ref.read(apiProvider).adminListUsers());
  }

  /// Parse the free-text field into a list of phone numbers. Accepts numbers
  /// separated by newlines, commas, or semicolons.
  List<String> _parsePhones() {
    return _phonesCtrl.text
        .split(RegExp(r'[\n,;]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> _uploadPhones() async {
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

  /// Shared upload path used by both contacts import and manual entry.
  Future<void> _upload(List<String> phones) async {
    setState(() => _uploading = true);
    try {
      final result = await ref.read(apiProvider).uploadContacts(phones);
      _snack('Added ${result['added']} new numbers (${result['valid']} valid of ${result['received']}).');
    } catch (e) {
      _snack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Invite list', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Text(
                        'Choose who can sign up. Each number becomes their invite — they just '
                        'enter it to join. You can change this anytime.'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.contacts),
                      label: Text(_uploading ? 'Adding…' : 'Pick from contacts'),
                      onPressed: _uploading ? null : _importFromContacts,
                    ),
                    const SizedBox(height: 16),
                    const Text('Or add numbers manually',
                        style: TextStyle(color: Color(0xFF848490), fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _phonesCtrl,
                      keyboardType: TextInputType.phone,
                      minLines: 2,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        hintText: '+15551234567\n+15557654321',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Add typed numbers'),
                      onPressed: _uploading ? null : _uploadPhones,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Members', style: Theme.of(context).textTheme.titleMedium),
          ),
          FutureBuilder<List<User>>(
            future: _users,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                    padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
              }
              final users = snap.data ?? [];
              return Column(
                children: users
                    .map((u) => ListTile(
                          leading: Avatar(name: u.name, mediaId: u.profileMediaId),
                          title: Text(u.name),
                          subtitle: Text(u.isAdmin ? 'Admin' : u.phone),
                          trailing: u.isAdmin
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.person_remove_outlined),
                                  tooltip: 'Remove member',
                                  onPressed: () => _confirmRevoke(u),
                                ),
                        ))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRevoke(User u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${u.name}?'),
        content: const Text('They will no longer be able to log in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(apiProvider).revokeUser(u.id);
      _refreshUsers();
    }
  }
}

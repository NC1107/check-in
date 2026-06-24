import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../widgets/auth_image.dart';

/// AdminScreen lets the admin upload their phone contacts (which become the allowlist
/// of who can sign up) and manage existing members.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  late Future<List<User>> _users;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _users = ref.read(apiProvider).adminListUsers();
  }

  void _refreshUsers() {
    setState(() => _users = ref.read(apiProvider).adminListUsers());
  }

  Future<void> _uploadContacts() async {
    setState(() => _uploading = true);
    try {
      if (!await FlutterContacts.requestPermission()) {
        _snack('Contacts permission denied');
        return;
      }
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final phones = <String>[];
      for (final c in contacts) {
        for (final p in c.phones) {
          if (p.number.trim().isNotEmpty) phones.add(p.number);
        }
      }
      if (phones.isEmpty) {
        _snack('No phone numbers found in contacts');
        return;
      }
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
                        'Upload your phone contacts to choose who can sign up. Each contact’s '
                        'phone number becomes their invite — they just enter it to join.'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.contacts),
                      label: Text(_uploading ? 'Uploading…' : 'Upload my contacts'),
                      onPressed: _uploading ? null : _uploadContacts,
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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../notifications/push_messaging.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/auth_image.dart';
import '../../widgets/user_avatar.dart';
import '../admin/admin_screen.dart';
import '../feed/post_card.dart';
import '../settings/appearance_screen.dart';
import '../settings/notification_settings_screen.dart';

/// ProfileScreen shows a person's profile and their timeline. For the signed-in user it
/// also offers profile editing and (for admins) member/invite management.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, required this.userId, required this.isSelf});

  final int userId;
  final bool isSelf;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late Future<(User, List<Post>)> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<(User, List<Post>)> _load() async {
    final api = ref.read(apiProvider);
    final user = await api.getUser(widget.userId);
    final posts = await api.userPosts(widget.userId);
    return (user, posts);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _editProfile(User user) async {
    final updated = await showModalBottomSheet<User>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _EditProfileSheet(user: user),
    );
    if (updated != null) {
      ref.read(sessionProvider.notifier).updateUser(updated);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: Text(widget.isSelf ? 'My profile' : 'Profile',
            style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
        actions: [
          if (widget.isSelf)
            IconButton(
              tooltip: 'Appearance',
              icon: const Icon(Icons.palette_outlined, color: kFgSecondary),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AppearanceScreen()),
              ),
            ),
          if (widget.isSelf)
            IconButton(
              tooltip: 'Notifications',
              icon: const Icon(Icons.notifications_none_rounded, color: kFgSecondary),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
              ),
            ),
          if (widget.isSelf)
            IconButton(
              tooltip: 'Log out',
              icon: const Icon(Icons.logout, color: kFgSecondary),
              onPressed: () async {
                final api = ref.read(apiProvider);
                // Drop this device's push token while the session is still valid.
                await clearDeviceToken(api);
                try {
                  await api.logout();
                } catch (_) {}
                await ref.read(sessionProvider.notifier).signOut();
              },
            ),
        ],
      ),
      body: FutureBuilder<(User, List<Post>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator(color: context.accent));
          }
          if (snap.hasError) {
            return Center(
              child: Text('Could not load profile.\n${snap.error}',
                  textAlign: TextAlign.center, style: const TextStyle(color: kFgSecondary)),
            );
          }
          final (user, posts) = snap.data!;
          return ListView(
            children: [
              _header(user, posts.length),
              const Divider(color: kBorder, height: 1),
              if (posts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child:
                      Center(child: Text('No check-ins yet.', style: TextStyle(color: kFgMuted))),
                ),
              ...posts.map((p) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 6, 16, 6),
                          child: Text(
                            DateFormat.yMMMMd().format(p.createdAt.toLocal()),
                            style: TextStyle(
                                color: context.accent, fontWeight: FontWeight.w600, fontSize: 12),
                          ),
                        ),
                        PostCard(key: ValueKey(p.id), post: p, onDeleted: _reload),
                      ],
                    ),
                  )),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _header(User user, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        children: [
          UserAvatar(name: user.name, mediaId: user.profileMediaId, size: 88, colorSeed: user.id),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(user.name,
                    style: const TextStyle(
                        color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 22)),
              ),
              if (user.isAdmin) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: context.accentLight,
                    borderRadius: BorderRadius.circular(9999),
                  ),
                  child: Text('HOST',
                      style: TextStyle(
                          color: context.accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          letterSpacing: 0.5)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text('$count ${count == 1 ? 'check-in' : 'check-ins'}',
              style: const TextStyle(color: kFgMuted, fontSize: 13)),
          if (widget.isSelf) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _editProfile(user),
                    icon: const Icon(Icons.edit_outlined, size: 18, color: kFgPrimary),
                    label: const Text('Edit profile', style: TextStyle(color: kFgPrimary)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: kBorder),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                if (user.isAdmin) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AdminScreen()),
                      ),
                      icon: const Icon(Icons.group_outlined, size: 18),
                      label: const Text('Members'),
                      style: FilledButton.styleFrom(
                        backgroundColor: context.accent,
                        foregroundColor: context.onAccent,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Bottom sheet to edit the signed-in user's display name and photo. Pops the updated
/// User on success.
class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({required this.user});
  final User user;

  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  late final _name = TextEditingController(text: widget.user.name);
  late final _firstName = TextEditingController(text: widget.user.firstName);
  late final _lastName = TextEditingController(text: widget.user.lastName);
  XFile? _photo;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _firstName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x != null && mounted) setState(() => _photo = x);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final first = _firstName.text.trim();
    final last = _lastName.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Display name cannot be empty.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      var updated = widget.user;
      final nameChanged = name != widget.user.name ||
          first != widget.user.firstName ||
          last != widget.user.lastName;
      if (nameChanged) {
        updated = await api.updateProfile(name: name, firstName: first, lastName: last);
      }
      if (_photo != null) {
        final mediaId = await api.uploadImage(_photo!.path);
        updated = await api.setProfilePhoto(mediaId);
      }
      if (mounted) Navigator.of(context).pop(updated);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 10, bottom: bottomInset + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: kBorder, borderRadius: BorderRadius.circular(9999)),
            ),
          ),
          const Text('Edit profile',
              style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 18),
          Center(
            child: GestureDetector(
              onTap: _pickPhoto,
              child: SizedBox(
                width: 96,
                height: 96,
                child: Stack(
                  children: [
                    ClipOval(
                      child: SizedBox(
                        width: 96,
                        height: 96,
                        child: _photo != null
                            ? Image.file(File(_photo!.path), fit: BoxFit.cover)
                            : (widget.user.profileMediaId != null
                                ? AuthImage(mediaId: widget.user.profileMediaId!)
                                : Container(
                                    color: kBgSurfaceHover,
                                    alignment: Alignment.center,
                                    child: Text(
                                      widget.user.name.isNotEmpty
                                          ? widget.user.name[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                          color: kFgPrimary,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 32),
                                    ),
                                  )),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: context.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: kBgSurface, width: 3),
                        ),
                        child: Icon(Icons.photo_camera, size: 15, color: context.onAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          const FieldLabel('Full name'),
          Row(
            children: [
              Expanded(
                child: AppTextField(
                  controller: _firstName,
                  hint: 'First',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppTextField(
                  controller: _lastName,
                  hint: 'Last',
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const FieldLabel('Display name'),
          AppTextField(
            controller: _name,
            hint: 'What your circle sees',
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          const Text('This is the name shown on your check-ins and comments.',
              style: TextStyle(color: kFgMuted, fontSize: 12, height: 1.4)),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: kLike, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          PrimaryButton(
            label: 'Save',
            enabled: _name.text.trim().isNotEmpty && !_busy,
            busy: _busy,
            onTap: _save,
          ),
        ],
      ),
    );
  }
}

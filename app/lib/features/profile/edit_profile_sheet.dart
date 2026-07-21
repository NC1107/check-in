import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/auth_image.dart';
import '../settings/appearance_screen.dart';
import 'photo_crop_screen.dart';

/// Bottom sheet to edit the signed-in user's display name and photo on one group
/// ([groupId], null = the current group - identity is per-server). Pops the updated
/// User on success; the caller refreshes the session/screen.
class EditProfileSheet extends ConsumerStatefulWidget {
  const EditProfileSheet({super.key, required this.user, this.groupId});

  final User user;
  final String? groupId;

  @override
  ConsumerState<EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<EditProfileSheet> {
  late final _name = TextEditingController(text: widget.user.name);
  late final _firstName = TextEditingController(text: widget.user.firstName);
  late final _lastName = TextEditingController(text: widget.user.lastName);
  Uint8List? _photoBytes;
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
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    final cropped = await PhotoCropScreen.crop(context, bytes);
    if (cropped != null && mounted) setState(() => _photoBytes = cropped);
  }

  /// Applies the name fields to [base] on [api] if they actually changed, otherwise
  /// returns [base] untouched. Shared by Save (this group only) and Sync (this group,
  /// before fanning the photo out to the rest).
  Future<User> _applyNameIfChanged(ApiClient api, User base) async {
    final name = _name.text.trim();
    final first = _firstName.text.trim();
    final last = _lastName.text.trim();
    final changed = name != base.name || first != base.firstName || last != base.lastName;
    if (!changed) return base;
    return api.updateProfile(name: name, firstName: first, lastName: last);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Display name cannot be empty.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(contentApiProvider(widget.groupId));
      var updated = await _applyNameIfChanged(api, widget.user);
      if (_photoBytes != null) {
        final mediaId = await api.uploadImageBytes(_photoBytes!, filename: 'profile.png');
        updated = await api.setProfilePhoto(mediaId);
      }
      if (mounted) Navigator.of(context).pop(updated);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Saves this group's own edits (name + photo, same as Save), then pushes just the
  /// photo - not the name, each group keeps its own - to every other signed-in group.
  /// Media ids are per-server, so the same bytes are re-uploaded once per group.
  Future<void> _syncEverywhere() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Display name cannot be empty.');
      return;
    }
    if (_photoBytes == null && widget.user.profileMediaId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final myApi = ref.read(contentApiProvider(widget.groupId));
      var mine = await _applyNameIfChanged(myApi, widget.user);
      final photoBytes = _photoBytes ?? await myApi.downloadMedia(widget.user.profileMediaId!);
      final mediaId = await myApi.uploadImageBytes(photoBytes, filename: 'profile.png');
      mine = await myApi.setProfilePhoto(mediaId);
      final myGroupId = ref.read(contentAccountProvider(widget.groupId))?.id;
      if (myGroupId != null) {
        ref.read(multiSessionProvider.notifier).updateUser(myGroupId, mine);
      }

      final failed = <String>[];
      for (final g in ref.read(multiSessionProvider).signedIn) {
        if (g.id == myGroupId) continue;
        try {
          final api = ref.read(contentApiProvider(g.id));
          final id = await api.uploadImageBytes(photoBytes, filename: 'profile.png');
          final updated = await api.setProfilePhoto(id);
          ref.read(multiSessionProvider.notifier).updateUser(g.id, updated);
        } catch (_) {
          failed.add(g.displayName);
        }
      }
      if (!mounted) return;
      if (failed.isEmpty) {
        Navigator.of(context).pop(mine);
      } else {
        setState(() => _error = "Photo synced, but couldn't reach ${failed.join(', ')}.");
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not sync the photo. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final multiGroup = ref.watch(multiSessionProvider.select((s) => s.signedIn.length)) > 1;
    final hasPhoto = _photoBytes != null || widget.user.profileMediaId != null;
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
                        child: _photoBytes != null
                            ? Image.memory(_photoBytes!, fit: BoxFit.cover)
                            : (widget.user.profileMediaId != null
                                ? AuthImage(
                                    mediaId: widget.user.profileMediaId!, groupId: widget.groupId)
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
          const SizedBox(height: 14),
          // The app-wide accent color is part of "how my app looks", so it lives with
          // the profile rather than as a top-level settings entry.
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AppearanceScreen()),
            ),
            leading: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: context.accent, shape: BoxShape.circle),
            ),
            title: const Text('Appearance', style: TextStyle(color: kFgPrimary, fontSize: 15)),
            subtitle: const Text('Accent color for buttons and highlights',
                style: TextStyle(color: kFgMuted, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, size: 18, color: kFgMuted),
          ),
          if (multiGroup) ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: hasPhoto && !_busy ? _syncEverywhere : null,
              icon: const Icon(Icons.sync, size: 18),
              label: const Text('Sync photo to all groups'),
              style: OutlinedButton.styleFrom(
                foregroundColor: kFgPrimary,
                disabledForegroundColor: kFgMuted,
                side: const BorderSide(color: kBorder),
                padding: const EdgeInsets.symmetric(vertical: 10),
                minimumSize: const Size.fromHeight(0),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 6),
            const Text("Copies this photo to every group you're signed into. Names stay separate.",
                style: TextStyle(color: kFgMuted, fontSize: 12, height: 1.4)),
          ],
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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../notifications/birthday_notifier.dart';
import '../../state/app_state.dart';
import '../admin/admin_screen.dart';
import '../profile/profile_screen.dart';
import 'feed_screen.dart';

const _bgMain = Color(0xFF0A0A0B);
const _bgSurface = Color(0xFF1C1C1E);
const _bgSurfaceHover = Color(0xFF232326);
const _border = Color(0xFF27272A);
const _fgPrimary = Color(0xFFEDEDEF);
const _fgSecondary = Color(0xFFABABB0);
const _fgMuted = Color(0xFF848490);
const _accent = Color(0xFF5557E0);
const _accentLight = Color(0x295557E0);

/// HomeShell hosts the main tabs once a user is logged in.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduleBirthdayNotifications(ref.read(apiProvider));
    });
  }

  void _showCompose() {
    showModalBottomSheet<bool?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => const _ComposeSheet(),
    ).then((posted) {
      if (posted == true && _index != 0) setState(() => _index = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider).user;
    final isAdmin = me?.isAdmin ?? false;

    final pages = <Widget>[
      const FeedScreen(),
      if (me != null) ProfileScreen(userId: me.id, isSelf: true),
      if (isAdmin) const AdminScreen(),
    ];

    return Scaffold(
      backgroundColor: _bgMain,
      body: IndexedStack(index: _index, children: pages),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCompose,
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        elevation: 6,
        child: const Icon(Icons.add, size: 26),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        color: _bgMain,
        elevation: 0,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        child: SizedBox(
          height: 50,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                icon: Icon(
                  _index == 0 ? Icons.home : Icons.home_outlined,
                  size: 24,
                ),
                color: _index == 0 ? _accent : _fgMuted,
                onPressed: () => setState(() => _index = 0),
              ),
              const SizedBox(width: 56), // notch gap
              IconButton(
                icon: Icon(
                  _index == 1 ? Icons.person : Icons.person_outline,
                  size: 24,
                ),
                color: _index == 1 ? _accent : _fgMuted,
                onPressed: me != null ? () => setState(() => _index = 1) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline compose bottom sheet matching the design.
class _ComposeSheet extends ConsumerStatefulWidget {
  const _ComposeSheet();

  @override
  ConsumerState<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends ConsumerState<_ComposeSheet> {
  final _bodyCtrl = TextEditingController();
  XFile? _image;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (x != null && mounted) setState(() => _image = x);
  }

  Future<void> _submit() async {
    if (_image == null && _bodyCtrl.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      if (_image != null) {
        final mediaId = await api.uploadImage(_image!.path);
        await api.createPost(kind: 'image', body: _bodyCtrl.text.trim(), mediaId: mediaId);
      } else {
        await api.createPost(kind: 'text', body: _bodyCtrl.text.trim());
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not post. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider).user;
    final hasContent = _bodyCtrl.text.trim().isNotEmpty || _image != null;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 38,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 14),
            decoration: BoxDecoration(
              color: _border,
              borderRadius: BorderRadius.circular(9999),
            ),
          ),
          // Title row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: _fgSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  child: const Text('Cancel', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                ),
                const Expanded(
                  child: Text(
                    'New post',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _bodyCtrl,
                  builder: (_, __, ___) => TextButton(
                    onPressed: hasContent && !_busy ? _submit : null,
                    style: TextButton.styleFrom(
                      backgroundColor: hasContent ? _accent : _bgSurfaceHover,
                      foregroundColor: hasContent ? Colors.white : _fgMuted,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9999)),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Share', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Image preview
          if (_image != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(_image!.path),
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          // Text input
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (me != null) ...[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: _accent, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Text(
                      me.name.isNotEmpty ? me.name[0].toUpperCase() : 'Y',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        height: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: TextField(
                    controller: _bodyCtrl,
                    onChanged: (_) => setState(() {}),
                    minLines: 3,
                    maxLines: 6,
                    style: const TextStyle(color: _fgPrimary, fontSize: 16, height: 1.5),
                    decoration: const InputDecoration(
                      hintText: "What's going on?",
                      hintStyle: TextStyle(color: _fgMuted),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.only(top: 6),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13)),
            ),
          // Divider + photo button
          const Divider(color: _border, height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: OutlinedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.image_outlined, color: _accent, size: 19),
              label: Text(
                _image == null ? 'Add photo' : 'Change photo',
                style: const TextStyle(color: _fgSecondary, fontWeight: FontWeight.w600, fontSize: 13),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

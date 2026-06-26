import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:image_picker/image_picker.dart';
import 'package:native_exif/native_exif.dart';

import '../../notifications/birthday_notifier.dart';
import '../../notifications/push_messaging.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/user_avatar.dart';
import '../profile/profile_screen.dart';
import 'feed_screen.dart';

const _bgMain = kBgMain;
const _bgSurface = kBgSurface;
const _bgSurfaceHover = kBgSurfaceHover;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;

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
      final api = ref.read(apiProvider);
      scheduleBirthdayNotifications(api);
      // Logged in by the time the shell mounts, so register for cloud push now.
      requestDeviceToken(api);
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
      if (posted == true) {
        ref.invalidate(feedProvider); // surface the new post immediately
        if (_index != 0) setState(() => _index = 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider).user;

    // Admin/member management is reached from the profile (host badge + Members button),
    // so it isn't a bottom-nav destination.
    final pages = <Widget>[
      const FeedScreen(),
      if (me != null) ProfileScreen(userId: me.id, isSelf: true),
    ];

    return Scaffold(
      backgroundColor: _bgMain,
      body: IndexedStack(index: _index, children: pages),
      floatingActionButton: SizedBox(
        height: 58,
        width: 58,
        child: FloatingActionButton(
          onPressed: _showCompose,
          backgroundColor: context.accent,
          foregroundColor: context.onAccent,
          elevation: 4,
          shape: const CircleBorder(),
          child: const Icon(Icons.add, size: 28),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        color: _bgMain,
        elevation: 0,
        height: 64,
        padding: EdgeInsets.zero,
        shape: const CircularNotchedRectangle(),
        notchMargin: 9,
        child: DecoratedBox(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: _border))),
          child: Row(
            children: [
              _NavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                label: 'Feed',
                selected: _index == 0,
                onTap: () => setState(() => _index = 0),
              ),
              const SizedBox(width: 64), // FAB notch
              _NavItem(
                icon: Icons.person_outline,
                activeIcon: Icons.person_rounded,
                label: 'You',
                selected: _index == 1,
                onTap: me != null ? () => setState(() => _index = 1) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One bottom-bar destination: icon + label, tinted by selection.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.accent : _fgMuted;
    return Expanded(
      child: InkResponse(
        onTap: onTap,
        radius: 42,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? activeIcon : icon, size: 23, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
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
  static const _maxImages = 10;
  final _bodyCtrl = TextEditingController();
  final List<XFile> _images = [];
  String? _location; // coarse "City, Country" read from the photos, if any
  String? _locationSource; // path of the photo that supplied _location
  bool _locationCleared = false; // user removed the location manually; don't auto-refill
  bool _resolvingLocation = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _bodyCtrl.dispose();
    super.dispose();
  }

  // No imageQuality on picks: that re-encodes and strips EXIF, which we need to read the
  // photo's GPS. The server downscales + strips metadata on its end.
  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty || !mounted) return;
    setState(() {
      for (final x in picked) {
        if (_images.length < _maxImages) _images.add(x);
      }
    });
    await _resolveLocation();
  }

  Future<void> _takePhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera);
    if (x == null || !mounted) return;
    setState(() {
      if (_images.length < _maxImages) _images.add(x);
    });
    await _resolveLocation();
  }

  /// Read a place label from the first image that carries GPS, remembering which photo it
  /// came from. Skips if we already have one or the user cleared it manually.
  Future<void> _resolveLocation() async {
    if (_locationCleared || _location != null || _images.isEmpty) return;
    setState(() => _resolvingLocation = true);
    String? place;
    String? source;
    for (final x in _images) {
      place = await _photoPlace(x.path);
      if (place != null) {
        source = x.path;
        break;
      }
    }
    if (mounted) {
      setState(() {
        _location = place;
        _locationSource = source;
        _resolvingLocation = false;
      });
    }
  }

  /// Reads the photo's GPS on-device and reverse-geocodes it to a coarse "City, Country".
  /// Returns null when there's no location data. Raw coordinates never leave the phone.
  Future<String?> _photoPlace(String path) async {
    try {
      final exif = await Exif.fromPath(path);
      final coords = await exif.getLatLong();
      await exif.close();
      if (coords == null) return null;
      final marks = await placemarkFromCoordinates(coords.latitude, coords.longitude);
      if (marks.isEmpty) return null;
      final p = marks.first;
      final city = [p.locality, p.subAdministrativeArea, p.administrativeArea]
          .firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
      final parts = <String>[
        if (city != null) city,
        if (p.country != null && p.country!.isNotEmpty) p.country!,
      ];
      return parts.isEmpty ? null : parts.join(', ');
    } catch (_) {
      return null; // no permission, no GPS, or geocoder unavailable → just skip it
    }
  }

  Widget _thumb(int i) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(File(_images[i].path), width: 100, height: 100, fit: BoxFit.cover),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: () async {
              final removed = _images[i].path;
              setState(() => _images.removeAt(i));
              // If the removed photo is the one that supplied the location, drop it and
              // re-derive from the remaining photos so a deleted photo's place can't stay
              // attached to the post.
              if (removed == _locationSource) {
                setState(() {
                  _location = null;
                  _locationSource = null;
                });
                await _resolveLocation();
              }
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 15, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _mediaButton(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, color: context.accent, size: 19),
      label: Text(label,
          style: const TextStyle(color: _fgSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: _border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(vertical: 11),
      ),
    );
  }

  Future<void> _submit() async {
    if (_images.isEmpty && _bodyCtrl.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      if (_images.isNotEmpty) {
        final ids = <int>[];
        for (final x in _images) {
          ids.add(await api.uploadImage(x.path));
        }
        await api.createPost(
            kind: 'image', body: _bodyCtrl.text.trim(), mediaIds: ids, location: _location);
      } else {
        await api.createPost(kind: 'text', body: _bodyCtrl.text.trim());
      }
      if (mounted) Navigator.of(context).pop(true);
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = (data is Map && data['error'] is String)
          ? data['error'] as String
          : 'Could not share your check-in. Check your connection and try again.';
      if (mounted) setState(() => _error = msg);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not share your check-in. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider).user;
    final hasContent = _bodyCtrl.text.trim().isNotEmpty || _images.isNotEmpty;
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
                  child: const Text('Cancel',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                ),
                const Expanded(
                  child: Text(
                    'New check-in',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _bodyCtrl,
                  builder: (_, __, ___) => TextButton(
                    onPressed: hasContent && !_busy ? _submit : null,
                    style: TextButton.styleFrom(
                      backgroundColor: hasContent ? context.accent : _bgSurfaceHover,
                      foregroundColor: hasContent ? context.onAccent : _fgMuted,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9999)),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: _busy
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2, color: context.onAccent))
                        : const Text('Share',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Image previews — a removable thumbnail strip.
          if (_images.isNotEmpty)
            SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _images.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => _thumb(i),
              ),
            ),
          // Detected location (read from the photos, removable before posting)
          if (_images.isNotEmpty && (_resolvingLocation || _location != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  Icon(Icons.place_outlined, size: 16, color: context.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _resolvingLocation ? 'Checking location…' : _location!,
                      style: const TextStyle(color: _fgSecondary, fontSize: 13),
                    ),
                  ),
                  if (_location != null && !_resolvingLocation)
                    GestureDetector(
                      onTap: () => setState(() {
                        _location = null;
                        _locationSource = null;
                        _locationCleared = true;
                      }),
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 16, color: _fgMuted),
                      ),
                    ),
                ],
              ),
            ),
          // Text input
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (me != null) ...[
                  UserAvatar(name: me.name, size: 38, mediaId: me.profileMediaId, colorSeed: me.id),
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
              child: Text(_error!, style: const TextStyle(color: kLike, fontSize: 13)),
            ),
          // Divider + media buttons (gallery + live camera)
          const Divider(color: _border, height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Row(
              children: [
                Expanded(
                  child: _mediaButton(Icons.image_outlined, _images.isEmpty ? 'Photos' : 'Add more',
                      _pickFromGallery),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _mediaButton(Icons.photo_camera_outlined, 'Camera', _takePhoto),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

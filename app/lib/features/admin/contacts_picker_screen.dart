import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../../theme/accent.dart';
import '../../theme/tokens.dart';

// Theme tokens (centralized in theme/tokens.dart).
const _bgMain = kBgMain;
const _bgSurfaceHover = kBgSurfaceHover;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;

const _avatarPalette = [
  Color(0xFF5557E0),
  Color(0xFF13AF9D),
  Color(0xFFDD1C85),
  Color(0xFFE9960A),
  Color(0xFF8458E9),
  Color(0xFF22C55E),
  Color(0xFFEF4444),
  Color(0xFF0EA5E9),
];

/// A contact with one or more phone numbers, flattened for the picker. All numbers are
/// uploaded when selected so the friend matches whichever one they sign up with.
class _PickContact {
  _PickContact({required this.id, required this.name, required this.phones, required this.color});
  final String id;
  final String name;
  final List<String> phones;
  final Color color;
  String get phone => phones.first; // primary, shown in the row
  String get initial => name.isNotEmpty ? name[0].toUpperCase() : '?';
}

enum _Phase { intro, loading, list, blocked, error }

/// ContactsPickerScreen explains why it needs contacts, asks the user for permission
/// (the system dialog is only shown after the user opts in), then shows the device
/// contacts as a selectable list matching the design's "Invite your circle" step. Pops
/// with the selected phone numbers, or null if cancelled.
class ContactsPickerScreen extends StatefulWidget {
  const ContactsPickerScreen({super.key});

  @override
  State<ContactsPickerScreen> createState() => _ContactsPickerScreenState();
}

class _ContactsPickerScreenState extends State<ContactsPickerScreen> {
  _Phase _phase = _Phase.intro;
  bool _permanentlyBlocked = false;
  String? _error;
  List<_PickContact> _contacts = [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _maybeSkipIntro();
  }

  bool _isGranted(PermissionStatus s) =>
      s == PermissionStatus.granted || s == PermissionStatus.limited;

  /// If contacts access was already granted on a previous visit, skip the rationale
  /// and load straight away. check() never shows a dialog, so this won't prompt.
  Future<void> _maybeSkipIntro() async {
    try {
      final status = await FlutterContacts.permissions.check(PermissionType.read);
      if (_isGranted(status) && mounted) _loadContacts();
    } catch (_) {
      // Stay on the intro screen and let the user trigger the request.
    }
  }

  /// Triggered by the user tapping "Allow access to contacts" — this is the only place
  /// the system permission dialog is requested.
  Future<void> _requestThenLoad() async {
    setState(() => _phase = _Phase.loading);
    PermissionStatus status;
    try {
      status = await FlutterContacts.permissions.request(PermissionType.read);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not request contacts access: $e';
          _phase = _Phase.error;
        });
      }
      return;
    }
    if (_isGranted(status)) {
      _loadContacts();
    } else if (mounted) {
      setState(() {
        // Once permanently denied/restricted, request() won't prompt again — the user
        // has to enable it from system Settings.
        _permanentlyBlocked =
            status == PermissionStatus.permanentlyDenied || status == PermissionStatus.restricted;
        _phase = _Phase.blocked;
      });
    }
  }

  Future<void> _loadContacts() async {
    setState(() => _phase = _Phase.loading);
    try {
      final raw = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      final list = <_PickContact>[];
      var i = 0;
      for (final c in raw) {
        final nums = c.phones.map((p) => p.number.trim()).where((s) => s.isNotEmpty).toList();
        if (nums.isEmpty) continue;
        final display = (c.displayName ?? '').trim();
        final name = display.isEmpty ? nums.first : display;
        list.add(_PickContact(
          id: c.id ?? '$i-${nums.first}',
          name: name,
          phones: nums,
          color: _avatarPalette[i % _avatarPalette.length],
        ));
        i++;
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) {
        setState(() {
          _contacts = list;
          _phase = _Phase.list;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not read contacts: $e';
          _phase = _Phase.error;
        });
      }
    }
  }

  void _toggle(String id) {
    setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _contacts.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_contacts.map((c) => c.id));
      }
    });
  }

  void _continue() {
    // Upload every number of each selected contact so they match whichever they use.
    final phones =
        _contacts.where((c) => _selected.contains(c.id)).expand((c) => c.phones).toList();
    Navigator.of(context).pop(phones);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgMain,
      appBar: AppBar(
        backgroundColor: _bgMain,
        elevation: 0,
        foregroundColor: _fgSecondary,
        title: const Text('Invite your circle',
            style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: SafeArea(
        top: false,
        child: switch (_phase) {
          _Phase.intro => _introView(),
          _Phase.loading => Center(child: CircularProgressIndicator(color: context.accent)),
          _Phase.list => _listView(),
          _Phase.blocked => _blockedView(),
          _Phase.error => _messageView(
              icon: Icons.error_outline,
              text: _error ?? 'Something went wrong.',
              primaryLabel: 'Back',
              onPrimary: () => Navigator.of(context).pop(),
            ),
        },
      ),
    );
  }

  // ---- Phase: rationale (shown before the system prompt) ----

  Widget _introView() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 12, 26, 24),
      child: Column(
        children: [
          const Spacer(),
          Container(
            width: 64,
            height: 64,
            decoration:
                BoxDecoration(color: context.accentLight, borderRadius: BorderRadius.circular(18)),
            child: Icon(Icons.contacts_outlined, size: 30, color: context.accent),
          ),
          const SizedBox(height: 22),
          const Text('Find people to invite',
              textAlign: TextAlign.center,
              style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 22)),
          const SizedBox(height: 10),
          const Text(
            'Check-In is invite-only. Grant access to your contacts so you can pick who '
            'can join — their phone number becomes their invite. Nothing is uploaded until '
            'you choose who to add, and you can change it anytime.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _requestThenLoad,
              style: FilledButton.styleFrom(
                backgroundColor: context.accent,
                foregroundColor: context.onAccent,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Allow access to contacts',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: _fgMuted),
            child: const Text("I'll add numbers manually"),
          ),
        ],
      ),
    );
  }

  // ---- Phase: permission blocked ----

  Widget _blockedView() {
    return _messageView(
      icon: Icons.contacts_outlined,
      text: _permanentlyBlocked
          ? 'Contacts access is turned off. Enable it in Settings to pick invitees, '
              'or go back and add numbers manually.'
          : 'Contacts access was denied. You can try again, or go back and add numbers '
              'manually.',
      primaryLabel: _permanentlyBlocked ? 'Open Settings' : 'Try again',
      onPrimary:
          _permanentlyBlocked ? () => FlutterContacts.permissions.openSettings() : _requestThenLoad,
      secondaryLabel: 'Back',
      onSecondary: () => Navigator.of(context).pop(),
    );
  }

  Widget _messageView({
    required IconData icon,
    required String text,
    required String primaryLabel,
    required VoidCallback onPrimary,
    String? secondaryLabel,
    VoidCallback? onSecondary,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: _fgMuted),
            const SizedBox(height: 16),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onPrimary,
                style: FilledButton.styleFrom(
                  backgroundColor: context.accent,
                  foregroundColor: context.onAccent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(primaryLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            if (secondaryLabel != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: onSecondary,
                style: TextButton.styleFrom(foregroundColor: _fgMuted),
                child: Text(secondaryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- Phase: selectable list ----

  Widget _listView() {
    final allSelected = _contacts.isNotEmpty && _selected.length == _contacts.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Only the people you select will be able to sign up. You can change this '
                'anytime.',
                style: TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${_selected.length} of ${_contacts.length} selected',
                      style: const TextStyle(
                          color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 12)),
                  GestureDetector(
                    onTap: _toggleAll,
                    behavior: HitTestBehavior.opaque,
                    child: Text(allSelected ? 'Clear all' : 'Select all',
                        style: TextStyle(
                            color: context.accent, fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _contacts.isEmpty
              ? const Center(
                  child: Text('No contacts with phone numbers found.',
                      style: TextStyle(color: _fgMuted)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _contacts.length,
                  itemBuilder: (_, i) => _contactRow(_contacts[i]),
                ),
        ),
        _footer(),
      ],
    );
  }

  Widget _contactRow(_PickContact c) {
    final on = _selected.contains(c.id);
    return GestureDetector(
      onTap: () => _toggle(c.id),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: c.color, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text(c.initial,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: _fgPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
                  Text(c.phone,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _fgMuted, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: on ? context.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: on ? context.accent : _border, width: 1.5),
              ),
              child: on ? Icon(Icons.check, size: 17, color: context.onAccent) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    final n = _selected.length;
    final enabled = n > 0;
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: _border))),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: enabled ? _continue : null,
          style: FilledButton.styleFrom(
            backgroundColor: context.accent,
            disabledBackgroundColor: _bgSurfaceHover,
            foregroundColor: context.onAccent,
            disabledForegroundColor: _fgMuted,
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(enabled ? 'Invite $n ${n == 1 ? 'number' : 'numbers'}' : 'Select contacts',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ),
      ),
    );
  }
}

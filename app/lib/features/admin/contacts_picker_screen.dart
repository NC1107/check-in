import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

// Design tokens — Check-In dark design system
const _bgMain = Color(0xFF0A0A0B);
const _bgSurfaceHover = Color(0xFF232326);
const _border = Color(0xFF27272A);
const _fgPrimary = Color(0xFFEDEDEF);
const _fgSecondary = Color(0xFFABABB0);
const _fgMuted = Color(0xFF848490);
const _accent = Color(0xFF5557E0);
const _onAccent = Colors.white;

const _avatarPalette = [
  Color(0xFF5557E0), Color(0xFF13AF9D), Color(0xFFDD1C85),
  Color(0xFFE9960A), Color(0xFF8458E9), Color(0xFF22C55E),
  Color(0xFFEF4444), Color(0xFF0EA5E9),
];

/// A contact with a usable phone number, flattened for the picker.
class _PickContact {
  _PickContact({required this.id, required this.name, required this.phone, required this.color});
  final String id;
  final String name;
  final String phone;
  final Color color;
  String get initial => name.isNotEmpty ? name[0].toUpperCase() : '?';
}

/// ContactsPickerScreen requests contacts permission, shows the device contacts as a
/// selectable list (matching the design's "Invite your circle" step), and pops with the
/// selected phone numbers. Returns null if cancelled or permission denied.
class ContactsPickerScreen extends StatefulWidget {
  const ContactsPickerScreen({super.key});

  @override
  State<ContactsPickerScreen> createState() => _ContactsPickerScreenState();
}

class _ContactsPickerScreenState extends State<ContactsPickerScreen> {
  bool _loading = true;
  String? _error;
  List<_PickContact> _contacts = [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final status = await FlutterContacts.permissions.request(PermissionType.read);
      final granted =
          status == PermissionStatus.granted || status == PermissionStatus.limited;
      if (!granted) {
        setState(() {
          _loading = false;
          _error = 'Contacts permission denied. You can enable it in Settings, '
              'or add numbers manually instead.';
        });
        return;
      }
      final raw = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      final list = <_PickContact>[];
      var i = 0;
      for (final c in raw) {
        if (c.phones.isEmpty) continue;
        final number = c.phones.first.number.trim();
        if (number.isEmpty) continue;
        final display = (c.displayName ?? '').trim();
        final name = display.isEmpty ? number : display;
        list.add(_PickContact(
          id: c.id ?? '$i-$number',
          name: name,
          phone: number,
          color: _avatarPalette[i % _avatarPalette.length],
        ));
        i++;
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _contacts = list;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Could not read contacts: $e';
      });
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
    final phones = _contacts
        .where((c) => _selected.contains(c.id))
        .map((c) => c.phone)
        .toList();
    Navigator.of(context).pop(phones);
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _contacts.isNotEmpty && _selected.length == _contacts.length;
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
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _accent))
            : _error != null
                ? _errorView()
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 4, 22, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Check-In is invite-only. Choose who can join — only these numbers '
                              'will be able to sign up. You can change this anytime.',
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
                                      style: const TextStyle(
                                          color: _accent, fontWeight: FontWeight.w600, fontSize: 13)),
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
                  ),
      ),
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
                color: on ? _accent : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: on ? _accent : _border, width: 1.5),
              ),
              child: on ? const Icon(Icons.check, size: 17, color: _onAccent) : null,
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
            backgroundColor: _accent,
            disabledBackgroundColor: _bgSurfaceHover,
            foregroundColor: _onAccent,
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

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.contacts_outlined, size: 40, color: _fgMuted),
            const SizedBox(height: 16),
            Text(_error ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5)),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: _fgPrimary,
                side: const BorderSide(color: _border),
              ),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}

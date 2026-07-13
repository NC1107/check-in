import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../notifications/birthday_notifier.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';

/// Per-account push toggles. These map to the server's notify_posts / notify_replies
/// columns, so turning one off stops that kind of push to *all* of this account's
/// devices. Birthday reminders are scheduled on-device and aren't affected here.
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends ConsumerState<NotificationSettingsScreen> {
  bool _loading = true;
  NotifyPrefs _prefs = const NotifyPrefs(
      posts: true,
      replies: true,
      likes: true,
      digestEnabled: false,
      digestHour: 20,
      digestOffset: 0);
  int _leadDays = 0;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(apiProvider).notificationPrefs();
      final leadDays = await birthdayLeadDays();
      if (!mounted) return;
      setState(() {
        _prefs = prefs;
        _leadDays = leadDays;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your notification settings.';
        _loading = false;
      });
    }
  }

  Future<void> _update({
    bool? posts,
    bool? replies,
    bool? likes,
    bool? digestEnabled,
    int? digestHour,
  }) async {
    // Optimistic flip so the control feels instant; revert if the server rejects it.
    final prev = _prefs;
    setState(() {
      _prefs = _prefs.copyWith(
        posts: posts,
        replies: replies,
        likes: likes,
        digestEnabled: digestEnabled,
        digestHour: digestHour,
      );
      _saving = true;
    });
    try {
      final result = await ref.read(apiProvider).updateNotificationPrefs(
            posts: posts,
            replies: replies,
            likes: likes,
            digestEnabled: digestEnabled,
            digestHour: digestHour,
            // Always restate the offset when changing the window, so the server resolves
            // "their 8pm" against where they actually are right now.
            digestOffset: (digestEnabled != null || digestHour != null)
                ? DateTime.now().timeZoneOffset.inMinutes
                : null,
          );
      if (!mounted) return;
      setState(() {
        _prefs = result;
        _saving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _prefs = prev;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't update - check your connection.")),
      );
    }
  }

  /// Picks the hour the daily summary arrives. Only the hour is used - the server matches
  /// on the member's local hour - so any minutes the picker returns are dropped.
  Future<void> _editDigestTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _prefs.digestHour, minute: 0),
      helpText: 'Summary arrives at',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(primary: context.accent),
        ),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    await _update(digestHour: picked.hour);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: const Text('Notifications',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: context.accent))
          : _error != null
              ? Center(
                  child: Text(_error!,
                      textAlign: TextAlign.center, style: const TextStyle(color: kFgSecondary)))
              : ListView(
                  children: [
                    const SizedBox(height: 8),
                    _toggle(
                      title: 'New check-ins',
                      subtitle: 'When someone in your group shares a check-in',
                      value: _prefs.posts,
                      onChanged: _saving ? null : (v) => _update(posts: v),
                    ),
                    // The digest only makes sense as a way to *receive* new check-ins, so
                    // it's nested under that toggle and hidden when it's off entirely.
                    if (_prefs.posts) ...[
                      _toggle(
                        title: 'Send as a daily summary',
                        subtitle: _prefs.digestEnabled
                            ? 'One notification a day instead of one per check-in'
                            : 'A notification each time someone checks in',
                        value: _prefs.digestEnabled,
                        onChanged: _saving ? null : (v) => _update(digestEnabled: v),
                        inset: true,
                      ),
                      if (_prefs.digestEnabled)
                        ListTile(
                          contentPadding: const EdgeInsets.only(left: 36, right: 20),
                          title: const Text('Summary time',
                              style: TextStyle(
                                  color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
                          subtitle: const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Text('e.g. "8 new check-ins while you were away"',
                                style: TextStyle(color: kFgMuted, fontSize: 13)),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_prefs.digestLabel,
                                  style: TextStyle(
                                      color: context.accent, fontWeight: FontWeight.w600)),
                              const SizedBox(width: 4),
                              const Icon(Icons.chevron_right, color: kFgMuted, size: 20),
                            ],
                          ),
                          onTap: _saving ? null : _editDigestTime,
                        ),
                    ],
                    const Divider(color: kBorder, height: 1, indent: 16, endIndent: 16),
                    _toggle(
                      title: 'Replies',
                      subtitle: 'When someone comments on your check-in',
                      value: _prefs.replies,
                      onChanged: _saving ? null : (v) => _update(replies: v),
                    ),
                    const Divider(color: kBorder, height: 1, indent: 16, endIndent: 16),
                    _toggle(
                      title: 'Likes',
                      subtitle: 'When someone likes your check-in',
                      value: _prefs.likes,
                      onChanged: _saving ? null : (v) => _update(likes: v),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text(
                        'Replies and likes are always sent as they happen - the summary '
                        'only groups new check-ins.',
                        style: TextStyle(color: kFgMuted, fontSize: 12.5, height: 1.4),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 26, 20, 6),
                      child: Text('BIRTHDAYS',
                          style: TextStyle(
                              color: kFgMuted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6)),
                    ),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                      title: const Text('Early heads-up',
                          style: TextStyle(
                              color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          _leadDays == 0
                              ? 'Only on the day'
                              : 'On the day, plus $_leadDays ${_leadDays == 1 ? 'day' : 'days'} before',
                          style: const TextStyle(color: kFgMuted, fontSize: 13),
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_leadDays == 0 ? 'Off' : '$_leadDays d',
                              style: TextStyle(color: context.accent, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right, color: kFgMuted, size: 20),
                        ],
                      ),
                      onTap: _editLeadDays,
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text(
                        'Birthday reminders are scheduled on your device and stay on '
                        'whether or not the push notifications above are enabled.',
                        style: TextStyle(color: kFgMuted, fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
    );
  }

  /// Prompts for the early-reminder lead time (in days), persists it, and reschedules every
  /// connected group's birthdays so the change takes effect immediately.
  Future<void> _editLeadDays() async {
    final controller = TextEditingController(text: _leadDays == 0 ? '' : '$_leadDays');
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: const Text('Early birthday reminder',
            style: TextStyle(color: kFgPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'How many days ahead should we remind you of birthdays? '
              'Leave blank for only on the day.',
              style: TextStyle(color: kFgSecondary, fontSize: 13.5, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(color: kFgPrimary, fontSize: 16),
              decoration: InputDecoration(
                suffixText: 'days before',
                suffixStyle: const TextStyle(color: kFgMuted),
                hintText: '0',
                hintStyle: const TextStyle(color: kFgMuted),
                enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: kBorder)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.accent)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: kFgSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.accent),
            onPressed: () {
              final n = (int.tryParse(controller.text.trim()) ?? 0).clamp(0, birthdayMaxLeadDays);
              Navigator.pop(ctx, n);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (days == null || !mounted) return;
    setState(() => _leadDays = days);
    await setBirthdayLeadDays(days);
    final session = ref.read(multiSessionProvider);
    await scheduleBirthdayNotifications([
      for (final g in session.signedIn)
        (api: ref.read(apiForGroupProvider(g.id)), id: g.id, name: g.displayName),
    ]);
  }

  Widget _toggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    bool inset = false, // nested under the toggle it depends on
  }) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: context.accent,
      contentPadding: EdgeInsets.only(left: inset ? 36 : 20, right: 20),
      title: Text(title,
          style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(subtitle, style: const TextStyle(color: kFgMuted, fontSize: 13)),
      ),
    );
  }
}

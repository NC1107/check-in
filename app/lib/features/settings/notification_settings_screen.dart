import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  bool _posts = true;
  bool _replies = true;
  bool _likes = true;
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
        _posts = prefs.posts;
        _replies = prefs.replies;
        _likes = prefs.likes;
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

  Future<void> _update({bool? posts, bool? replies, bool? likes}) async {
    // Optimistic flip so the switch feels instant; revert if the server rejects it.
    final prevPosts = _posts;
    final prevReplies = _replies;
    final prevLikes = _likes;
    setState(() {
      if (posts != null) _posts = posts;
      if (replies != null) _replies = replies;
      if (likes != null) _likes = likes;
      _saving = true;
    });
    try {
      final result = await ref.read(apiProvider).updateNotificationPrefs(
            posts: posts,
            replies: replies,
            likes: likes,
          );
      if (!mounted) return;
      setState(() {
        _posts = result.posts;
        _replies = result.replies;
        _likes = result.likes;
        _saving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _posts = prevPosts;
        _replies = prevReplies;
        _likes = prevLikes;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't update - check your connection.")),
      );
    }
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
                      value: _posts,
                      onChanged: _saving ? null : (v) => _update(posts: v),
                    ),
                    const Divider(color: kBorder, height: 1, indent: 16, endIndent: 16),
                    _toggle(
                      title: 'Replies',
                      subtitle: 'When someone comments on your check-in',
                      value: _replies,
                      onChanged: _saving ? null : (v) => _update(replies: v),
                    ),
                    const Divider(color: kBorder, height: 1, indent: 16, endIndent: 16),
                    _toggle(
                      title: 'Likes',
                      subtitle: 'When someone likes your check-in',
                      value: _likes,
                      onChanged: _saving ? null : (v) => _update(likes: v),
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
  }) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: context.accent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      title: Text(title,
          style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(subtitle, style: const TextStyle(color: kFgMuted, fontSize: 13)),
      ),
    );
  }
}

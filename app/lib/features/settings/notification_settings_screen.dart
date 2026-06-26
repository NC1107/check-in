import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      if (!mounted) return;
      setState(() {
        _posts = prefs.posts;
        _replies = prefs.replies;
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

  Future<void> _update({bool? posts, bool? replies}) async {
    // Optimistic flip so the switch feels instant; revert if the server rejects it.
    final prevPosts = _posts;
    final prevReplies = _replies;
    setState(() {
      if (posts != null) _posts = posts;
      if (replies != null) _replies = replies;
      _saving = true;
    });
    try {
      final result = await ref.read(apiProvider).updateNotificationPrefs(
            posts: posts,
            replies: replies,
          );
      if (!mounted) return;
      setState(() {
        _posts = result.posts;
        _replies = result.replies;
        _saving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _posts = prevPosts;
        _replies = prevReplies;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't update — check your connection.")),
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
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 22, 20, 0),
                      child: Text(
                        'Birthday reminders are scheduled on your device and stay on '
                        'whether or not these are enabled.',
                        style: TextStyle(color: kFgMuted, fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
    );
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/user_avatar.dart';
import '../feed/post_card.dart';
import '../settings/settings_screen.dart';

/// ProfileScreen shows a person's profile and their timeline. For the signed-in user it
/// also offers profile editing and (for admins) member/invite management. Identity is
/// per-group: [groupId] says which connected group this profile lives on (null = the
/// current group), and log out / delete only affect that group.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, required this.userId, required this.isSelf, this.groupId});

  final int userId;
  final bool isSelf;
  final String? groupId;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late Future<(User, List<Post>)> _future;
  bool? _isBlocked; // null = not yet loaded

  @override
  void initState() {
    super.initState();
    _future = _load();
    if (!widget.isSelf) _loadBlockStatus();
  }

  Future<(User, List<Post>)> _load() async {
    final api = ref.read(contentApiProvider(widget.groupId));
    final gid = ref.read(contentAccountProvider(widget.groupId))?.id;
    final user = await api.getUser(widget.userId);
    final posts = await api.userPosts(widget.userId);
    return (user, [for (final p in posts) gid == null ? p : p.withGroup(gid)]);
  }

  Future<void> _loadBlockStatus() async {
    try {
      final blocked = await ref.read(contentApiProvider(widget.groupId)).isBlocked(widget.userId);
      if (mounted) setState(() => _isBlocked = blocked);
    } catch (_) {}
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _toggleBlock() async {
    final currently = _isBlocked ?? false;
    final api = ref.read(contentApiProvider(widget.groupId));
    try {
      if (currently) {
        await api.unblockUser(widget.userId);
      } else {
        await api.blockUser(widget.userId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('User blocked. Their posts will no longer appear in your feed.')));
        }
      }
      if (mounted) setState(() => _isBlocked = !currently);
      // Refresh the feed so blocked posts disappear immediately.
      ref.invalidate(feedProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not update block status. Try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: Builder(builder: (context) {
          final groupCount = ref.watch(multiSessionProvider.select((s) => s.groups.length));
          final name =
              ref.watch(contentAccountProvider(widget.groupId).select((a) => a?.serverName));
          final base = widget.isSelf ? 'My profile' : 'Profile';
          return Text(groupCount > 1 && name != null ? '$base · $name' : base,
              style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18));
        }),
        actions: [
          if (widget.isSelf)
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined, color: kFgSecondary),
              // Reload on return so an edited name/photo shows immediately.
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => SettingsScreen(groupId: widget.groupId)))
                  .then((_) => _reload()),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not load profile.',
                      textAlign: TextAlign.center, style: TextStyle(color: kFgSecondary)),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _reload, child: const Text('Try again')),
                ],
              ),
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
          UserAvatar(
              name: user.name,
              mediaId: user.profileMediaId,
              size: 88,
              colorSeed: user.id,
              groupId: widget.groupId),
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
          if (!widget.isSelf) ...[
            // Block / Unblock for other members' profiles.
            if (_isBlocked != null) ...[
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _toggleBlock,
                icon: Icon(
                  _isBlocked! ? Icons.person_add_outlined : Icons.person_off_outlined,
                  size: 18,
                  color: _isBlocked! ? kFgSecondary : kLike,
                ),
                label: Text(
                  _isBlocked! ? 'Unblock' : 'Block',
                  style: TextStyle(color: _isBlocked! ? kFgSecondary : kLike),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: _isBlocked! ? kBorder : kLike),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  minimumSize: const Size.fromHeight(0),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/user_avatar.dart';
import '../feed/post_card.dart';
import '../settings/settings_screen.dart';

/// The signed-in user's own profile: one identity, every group. Merges their check-ins
/// from all signed-in groups (newest first, each card wearing its group's ring when more
/// than one group is connected) and sums the count. Unreachable groups degrade gracefully
/// - the rest still shows, with a notice.
class MyProfileScreen extends ConsumerStatefulWidget {
  const MyProfileScreen({super.key});

  @override
  ConsumerState<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends ConsumerState<MyProfileScreen> {
  late Future<(User, List<Post>, List<String>)> _future = _load();

  Future<(User, List<Post>, List<String>)> _load() async {
    final session = ref.read(multiSessionProvider);
    final groups = [
      for (final g in session.signedIn)
        if (g.user != null) g
    ];
    if (groups.isEmpty) throw StateError('No signed-in groups');
    final pages = await Future.wait([
      for (final g in groups)
        ref
            .read(contentApiProvider(g.id))
            .userPosts(g.user!.id)
            .then<List<Post>?>((posts) => [for (final p in posts) p.withGroup(g.id)])
            .catchError((_) => null),
    ]);
    final unreachable = <String>[];
    final loaded = <List<Post>>[];
    for (var i = 0; i < groups.length; i++) {
      final page = pages[i];
      if (page == null) {
        unreachable.add(groups[i].displayName);
      } else {
        loaded.add(page);
      }
    }
    if (loaded.isEmpty) throw StateError('No group reachable');
    // One human: the current group's identity fronts the merged timeline.
    final headerUser = session.current?.user ?? groups.first.user!;
    return (headerUser, mergeFeeds(loaded), unreachable);
  }

  void _reload() => setState(() => _future = _load());

  /// Reloads and completes when the fetch settles, so pull-to-refresh keeps the spinner up
  /// until the timeline is actually refreshed (errors surface via the FutureBuilder).
  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f.then((_) {}).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    // Adding/removing/re-logging a group changes what "my profile" covers.
    ref.listen(
      multiSessionProvider.select((s) => [for (final g in s.signedIn) g.id].join(',')),
      (_, __) => _reload(),
    );
    // A new check-in (created from the feed tab) reloads the profile so it appears here.
    ref.listen(profileRefreshProvider, (_, __) => _reload());
    final session = ref.watch(multiSessionProvider);
    final multi = session.signedIn.length > 1;
    final isHost = session.signedIn.any((g) => g.user?.isAdmin ?? false);
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: const Text('My profile',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, color: kFgSecondary),
            // Reload on return so an edited name/photo shows immediately.
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsScreen()))
                .then((_) => _reload()),
          ),
        ],
      ),
      body: FutureBuilder<(User, List<Post>, List<String>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const FeedSkeleton(topPadding: 12);
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
          final (user, posts, unreachable) = snap.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                _header(user, posts.length, isHost),
                const Divider(color: kBorder, height: 1),
                if (unreachable.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                    child: Text(
                      "Couldn't reach ${unreachable.join(', ')} - showing the rest.",
                      style: const TextStyle(color: kFgMuted, fontSize: 12.5),
                    ),
                  ),
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
                          PostCard(
                            key: ValueKey('${p.groupId}-${p.id}'),
                            post: p,
                            onDeleted: _reload,
                            groupColor: multi
                                ? ref.read(multiSessionProvider).byId(p.groupId)?.displayColor
                                : null,
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(User user, int count, bool isHost) {
    final groupId = ref.read(multiSessionProvider).current?.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        children: [
          GestureDetector(
            onTap: user.profileMediaId == null
                ? null
                : () => PhotoViewerScreen.open(context,
                    // A profile photo is an image by construction - the server rejects
                    // anything else for an avatar.
                    media: PostMedia.images([user.profileMediaId!]),
                    groupId: groupId),
            child: UserAvatar(
                name: user.name,
                mediaId: user.profileMediaId,
                size: 88,
                colorSeed: user.id,
                groupId: groupId),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(user.name,
                    style: const TextStyle(
                        color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 22)),
              ),
              if (isHost) ...[
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
          if (_titleLabels[user.title] case final label?) _titleChip(context, label),
          if (user.birthdayLabel.isNotEmpty) _birthdayLine(user.birthdayLabel),
        ],
      ),
    );
  }
}

/// A small centred "🎂 March 14" line for a profile header.
Widget _birthdayLine(String label) => Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text('🎂 $label', style: const TextStyle(color: kFgMuted, fontSize: 13)),
    );

/// Maps a bestowed title id (an award id from the recap system - see recap_card.dart's
/// Awards Night, now retired in favour of these) to its display label. longestThread reads
/// better as a person's title phrased as "Conversation Starter" than its old panel label
/// "Longest Thread". An id this build doesn't recognise (a future server's new award) has
/// no entry here and is silently skipped by the call sites below, rather than showing a raw
/// id like "some_new_award".
const _titleLabels = {
  'most_liked': 'Most Loved',
  'night_owl': 'Night Owl',
  'early_bird': 'Early Bird',
  'most_travelled': 'Most Travelled',
  'chatterbox': 'Chatterbox',
  'biggest_fan': 'Biggest Fan',
  'quiet_achiever': 'Quiet Achiever',
  'most_tagged': 'Most Tagged',
  'longest_thread': 'Conversation Starter',
};

/// A small pill for a member's bestowed title (e.g. "Quiet Achiever"), shown below the
/// check-in count on their profile.
Widget _titleChip(BuildContext context, String label) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration:
            BoxDecoration(color: context.accentLight, borderRadius: BorderRadius.circular(9999)),
        child: Text(label,
            style: TextStyle(
                color: context.accent,
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
                letterSpacing: 0.3)),
      ),
    );

/// ProfileScreen shows another member's profile and their timeline on one group.
/// Identity is per-group: [groupId] says which connected group this profile lives on
/// (null = the current group); blocking only affects that group.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, required this.userId, this.groupId});

  final int userId;
  final String? groupId;

  /// Picks the right screen for tapping a (userId, groupId) pair: [MyProfileScreen] when
  /// it's the viewer's own account in that group, otherwise the read-only [ProfileScreen].
  /// Every "tap a person" site in the app should push through here rather than
  /// constructing [ProfileScreen] directly - tapping your own avatar (e.g. on your own
  /// post cross-posted to another group) must land on your editable profile, not a
  /// stranger view of yourself with no settings access.
  ///
  /// Resolve this *before* any dismiss/close/pop step that might invalidate [context]
  /// (see the search delegate and the likers sheet call sites), then push the result.
  static Widget resolve(BuildContext context, {required int userId, String? groupId}) {
    final me = ProviderScope.containerOf(context, listen: false)
        .read(contentAccountProvider(groupId))
        ?.user;
    if (me != null && me.id == userId) return const MyProfileScreen();
    return ProfileScreen(userId: userId, groupId: groupId);
  }

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
    _loadBlockStatus();
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

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f.then((_) {}).catchError((_) {});
  }

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
              content: Text('User blocked. Their check-ins will no longer appear in your feed.')));
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
              ref.watch(contentAccountProvider(widget.groupId).select((a) => a?.displayName));
          return Text(groupCount > 1 && name != null ? 'Profile · $name' : 'Profile',
              style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18));
        }),
      ),
      body: FutureBuilder<(User, List<Post>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const FeedSkeleton(topPadding: 12);
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
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
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
            ),
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
          GestureDetector(
            onTap: user.profileMediaId == null
                ? null
                : () => PhotoViewerScreen.open(context,
                    media: PostMedia.images([user.profileMediaId!]), groupId: widget.groupId),
            child: UserAvatar(
                name: user.name,
                mediaId: user.profileMediaId,
                size: 88,
                colorSeed: user.id,
                groupId: widget.groupId),
          ),
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
          if (_titleLabels[user.title] case final label?) _titleChip(context, label),
          if (user.birthdayLabel.isNotEmpty) _birthdayLine(user.birthdayLabel),
          ...[
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

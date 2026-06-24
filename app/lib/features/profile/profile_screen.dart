import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../widgets/auth_image.dart';
import '../feed/post_card.dart';

/// ProfileScreen shows a person's profile and their timeline — a git-history-style,
/// reverse-chronological list of everything they've shared.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, required this.userId, required this.isSelf});

  final int userId;
  final bool isSelf;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late Future<(User, List<Post>)> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<(User, List<Post>)> _load() async {
    final api = ref.read(apiProvider);
    final user = await api.searchUsers('').then(
        (list) => list.firstWhere((u) => u.id == widget.userId, orElse: () => _placeholder()));
    final posts = await api.userPosts(widget.userId);
    return (user, posts);
  }

  User _placeholder() => User(id: widget.userId, name: 'Member', phone: '', isAdmin: false);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isSelf ? 'My timeline' : 'Timeline'),
        actions: [
          if (widget.isSelf)
            IconButton(
              tooltip: 'Log out',
              icon: const Icon(Icons.logout),
              onPressed: () async {
                try {
                  await ref.read(apiProvider).logout();
                } catch (_) {}
                await ref.read(sessionProvider.notifier).signOut();
              },
            ),
        ],
      ),
      body: FutureBuilder<(User, List<Post>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Could not load profile.\n${snap.error}'));
          }
          final (user, posts) = snap.data!;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Avatar(name: user.name, mediaId: user.profileMediaId, radius: 44),
                    const SizedBox(height: 12),
                    Text(user.name, style: Theme.of(context).textTheme.headlineSmall),
                    Text('${posts.length} check-ins',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Divider(),
              if (posts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No check-ins yet.')),
                ),
              // Timeline: a vertical, dated history of posts.
              ...posts.map((p) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          DateFormat.yMMMMd().format(p.createdAt.toLocal()),
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      PostCard(post: p),
                    ],
                  )),
            ],
          );
        },
      ),
    );
  }
}

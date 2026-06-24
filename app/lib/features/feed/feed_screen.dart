import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../profile/profile_screen.dart';
import 'post_card.dart';
import 'user_search_delegate.dart';

/// FeedScreen shows the chronological feed with a search bar and a filter button
/// (filter by person, sort by date).
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

enum _SortOrder { newest, oldest }

class _FeedScreenState extends ConsumerState<FeedScreen> {
  late Future<List<Post>> _future;
  _SortOrder _sort = _SortOrder.newest;

  @override
  void initState() {
    super.initState();
    _future = ref.read(apiProvider).feed();
  }

  Future<void> _refresh() async {
    final posts = await ref.read(apiProvider).feed();
    setState(() => _future = Future.value(posts));
  }

  List<Post> _applySort(List<Post> posts) {
    final sorted = [...posts];
    sorted.sort((a, b) => _sort == _SortOrder.newest
        ? b.createdAt.compareTo(a.createdAt)
        : a.createdAt.compareTo(b.createdAt));
    return sorted;
  }

  Future<void> _openUserSearch() async {
    final user = await showSearch<User?>(
      context: context,
      delegate: UserSearchDelegate(ref.read(apiProvider)),
    );
    if (user != null && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProfileScreen(userId: user.id, isSelf: false)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check-In'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search people',
            onPressed: _openUserSearch,
          ),
          PopupMenuButton<_FilterAction>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filter & sort',
            onSelected: (action) {
              switch (action) {
                case _FilterAction.byPerson:
                  _openUserSearch();
                case _FilterAction.newest:
                  setState(() => _sort = _SortOrder.newest);
                case _FilterAction.oldest:
                  setState(() => _sort = _SortOrder.oldest);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _FilterAction.byPerson,
                child: ListTile(leading: Icon(Icons.person_search), title: Text('Filter by person')),
              ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: _FilterAction.newest,
                checked: _sort == _SortOrder.newest,
                child: const Text('Newest first'),
              ),
              CheckedPopupMenuItem(
                value: _FilterAction.oldest,
                checked: _sort == _SortOrder.oldest,
                child: const Text('Oldest first'),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Post>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return ListView(children: [
                const SizedBox(height: 120),
                Center(child: Text('Could not load feed.\n${snap.error}', textAlign: TextAlign.center)),
              ]);
            }
            final posts = _applySort(snap.data ?? []);
            if (posts.isEmpty) {
              return ListView(children: const [
                SizedBox(height: 160),
                Center(child: Text('No posts yet. Tap + to share an update.')),
              ]);
            }
            return ListView.builder(
              itemCount: posts.length,
              itemBuilder: (context, i) => PostCard(post: posts[i]),
            );
          },
        ),
      ),
    );
  }
}

enum _FilterAction { byPerson, newest, oldest }

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../profile/profile_screen.dart';
import 'post_card.dart';
import 'user_search_delegate.dart';

// Design tokens
const _bgMain = Color(0xFF0A0A0B);
const _bgSurface = Color(0xFF1C1C1E);
const _border = Color(0xFF27272A);
const _fgSecondary = Color(0xFFABABB0);
const _fgMuted = Color(0xFF848490);
const _accent = Color(0xFF5557E0);
const _accentLight = Color(0x295557E0);

/// A feed item that renders the section date label with connector lines.
class _DateDivider extends StatelessWidget {
  const _DateDivider({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(width: 2, height: 12, color: _accentLight),
        Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
          decoration: BoxDecoration(
            color: _bgSurface,
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: _fgSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 11,
              letterSpacing: 0.3,
            ),
          ),
        ),
        Container(width: 2, height: 12, color: _accentLight),
      ],
    );
  }
}

/// Vertical connector between posts: line → accent dot → line.
class _GapConnector extends StatelessWidget {
  const _GapConnector();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(width: 2, height: 11, color: _accentLight),
        Container(
          width: 9,
          height: 9,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: const BoxDecoration(
            color: _accent,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: _accentLight, blurRadius: 0, spreadRadius: 3)],
          ),
        ),
        Container(width: 2, height: 11, color: _accentLight),
      ],
    );
  }
}

sealed class _FeedItem {}

class _DividerItem extends _FeedItem {
  _DividerItem(this.label);
  final String label;
}

class _GapItem extends _FeedItem {}

class _PostItem extends _FeedItem {
  _PostItem(this.post);
  final Post post;
}

String _dateLabel(DateTime dt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return '$diff days ago';
  return '${dt.month}/${dt.day}/${dt.year}';
}

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  late Future<List<Post>> _future;
  final _scrollCtrl = ScrollController();
  bool _searchHidden = false;
  double _lastScrollTop = 0;

  @override
  void initState() {
    super.initState();
    _future = ref.read(apiProvider).feed();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final top = _scrollCtrl.offset;
    final hidden = top > _lastScrollTop + 2 && top > 40;
    _lastScrollTop = top;
    if (hidden != _searchHidden) setState(() => _searchHidden = hidden);
  }

  Future<void> _refresh() async {
    final posts = await ref.read(apiProvider).feed();
    if (mounted) setState(() => _future = Future.value(posts));
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

  List<_FeedItem> _buildItems(List<Post> posts) {
    final items = <_FeedItem>[];
    String? lastLabel;
    for (final post in posts) {
      final label = _dateLabel(post.createdAt.toLocal());
      if (label != lastLabel) {
        items.add(_DividerItem(label));
        lastLabel = label;
      } else {
        items.add(_GapItem());
      }
      items.add(_PostItem(post));
    }
    return items;
  }

  Widget _buildItem(_FeedItem item) {
    return switch (item) {
      _DividerItem(:final label) => _DateDivider(label: label),
      _GapItem() => const _GapConnector(),
      _PostItem(:final post) => PostCard(post: post),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgMain,
      body: SafeArea(
        child: Stack(
          children: [
            // Feed list
            RefreshIndicator(
              onRefresh: _refresh,
              color: _accent,
              backgroundColor: _bgSurface,
              child: FutureBuilder<List<Post>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: _accent),
                    );
                  }
                  if (snap.hasError) {
                    return ListView(children: [
                      const SizedBox(height: 140),
                      Center(
                        child: Text(
                          'Could not load feed.\n${snap.error}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: _fgSecondary),
                        ),
                      ),
                    ]);
                  }
                  final posts = snap.data ?? [];
                  if (posts.isEmpty) {
                    return ListView(children: const [
                      SizedBox(height: 180),
                      Center(
                        child: Text(
                          'No posts yet.\nTap + to share an update.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: _fgMuted),
                        ),
                      ),
                    ]);
                  }
                  final items = _buildItems(posts);
                  return ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.only(top: 72, bottom: 24),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _buildItem(items[i]),
                  );
                },
              ),
            ),
            // Floating search bar — slides away on scroll down
            AnimatedSlide(
              offset: _searchHidden ? const Offset(0, -2) : Offset.zero,
              duration: const Duration(milliseconds: 280),
              curve: const Cubic(0.2, 0.8, 0.2, 1.0),
              child: AnimatedOpacity(
                opacity: _searchHidden ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: _searchHidden,
                  child: _SearchBar(onTap: _openUserSearch),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            color: _bgSurface,
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(color: Colors.black.withAlpha(76), blurRadius: 26, offset: const Offset(0, 10)),
            ],
          ),
          child: const Row(
            children: [
              Icon(Icons.search, size: 19, color: _fgMuted),
              SizedBox(width: 9),
              Text('Search people', style: TextStyle(color: _fgMuted, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

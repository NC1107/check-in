import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/auth_image.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail_screen.dart';
import '../profile/profile_screen.dart';

/// Full-content search across check-in captions, comments, and people. Queries are
/// debounced and only run at 2+ characters, navigating to the matched check-in or profile.
class GlobalSearchDelegate extends SearchDelegate<void> {
  GlobalSearchDelegate(this._api) : super(searchFieldLabel: 'Search check-ins & people');

  final ApiClient _api;
  Timer? _debounce;
  final _results = ValueNotifier<({List<Post> posts, List<User> people})?>(null);
  String _lastQueried = '';
  bool _closed = false;

  @override
  void close(BuildContext context, void result) {
    // SearchDelegate has no dispose hook; clean up here so a pending debounce timer and
    // its network call don't fire (and write to the notifier) after the user leaves.
    _closed = true;
    _debounce?.cancel();
    super.close(context, result);
    _results.dispose();
  }

  void _run(String q) {
    final query = q.trim();
    if (query == _lastQueried) return;
    _lastQueried = query;
    _debounce?.cancel();
    if (query.length < 2) {
      _results.value = (posts: <Post>[], people: <User>[]);
      return;
    }
    _results.value = null; // show loading
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final r = await _api.search(query);
        if (!_closed && _lastQueried == query) _results.value = r;
      } catch (_) {
        if (!_closed) _results.value = (posts: <Post>[], people: <User>[]);
      }
    });
  }

  @override
  ThemeData appBarTheme(BuildContext context) {
    return Theme.of(context).copyWith(
      scaffoldBackgroundColor: kBgMain,
      appBarTheme:
          const AppBarTheme(backgroundColor: kBgMain, elevation: 0, foregroundColor: kFgPrimary),
      inputDecorationTheme: const InputDecorationTheme(
        hintStyle: TextStyle(color: kFgMuted),
        border: InputBorder.none,
      ),
      textTheme: Theme.of(context).textTheme.copyWith(
            titleLarge: const TextStyle(color: kFgPrimary, fontSize: 17),
          ),
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.close, color: kFgSecondary),
            onPressed: () {
              query = '';
              _run('');
            },
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back, color: kFgSecondary),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildSuggestions(BuildContext context) {
    _run(query);
    return _resultsView(context);
  }

  @override
  Widget buildResults(BuildContext context) {
    _run(query);
    return _resultsView(context);
  }

  Widget _resultsView(BuildContext context) {
    if (query.trim().length < 2) {
      return Container(
        color: kBgMain,
        alignment: Alignment.topCenter,
        padding: const EdgeInsets.only(top: 60),
        child: const Text('Type at least 2 letters to search\ncaptions, comments, and people.',
            textAlign: TextAlign.center, style: TextStyle(color: kFgMuted, height: 1.5)),
      );
    }
    return Container(
      color: kBgMain,
      child: ValueListenableBuilder<({List<Post> posts, List<User> people})?>(
        valueListenable: _results,
        builder: (context, data, _) {
          if (data == null) {
            return Center(child: CircularProgressIndicator(color: context.accent));
          }
          if (data.people.isEmpty && data.posts.isEmpty) {
            return const Padding(
              padding: EdgeInsets.only(top: 60),
              child: Center(child: Text('No matches.', style: TextStyle(color: kFgMuted))),
            );
          }
          return ListView(
            children: [
              if (data.people.isNotEmpty) ...[
                _sectionLabel('PEOPLE'),
                ...data.people.map((u) => _personTile(context, u)),
              ],
              if (data.posts.isNotEmpty) ...[
                _sectionLabel('CHECK-INS'),
                ...data.posts.map((p) => _postTile(context, p)),
              ],
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(text,
            style: const TextStyle(
                color: kFgMuted, fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 0.5)),
      );

  Widget _personTile(BuildContext context, User u) {
    return ListTile(
      leading: UserAvatar(name: u.name, mediaId: u.profileMediaId, size: 40, colorSeed: u.id),
      title: Text(u.name, style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600)),
      onTap: () {
        final nav = Navigator.of(context);
        close(context, null);
        nav.push(MaterialPageRoute(builder: (_) => ProfileScreen(userId: u.id, isSelf: false)));
      },
    );
  }

  Widget _postTile(BuildContext context, Post p) {
    final preview = p.body.trim().isNotEmpty
        ? p.body.trim()
        : (p.kind == 'image' ? 'Photo check-in' : 'Check-in');
    return ListTile(
      leading: p.kind == 'image' && p.mediaId != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 40, height: 40, child: AuthImage(mediaId: p.mediaId!)),
            )
          : Container(
              width: 40,
              height: 40,
              decoration:
                  BoxDecoration(color: kBgSurfaceHover, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.chat_bubble_outline, size: 18, color: kFgMuted),
            ),
      title: Text(p.authorName,
          style: const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: kFgSecondary, fontSize: 13)),
      onTap: () {
        final nav = Navigator.of(context);
        close(context, null);
        nav.push(MaterialPageRoute(builder: (_) => PostDetailScreen(postId: p.id)));
      },
    );
  }
}

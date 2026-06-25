import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../widgets/auth_image.dart';
import '../../widgets/user_avatar.dart';

/// PostDetailScreen shows a single post with its full comment thread and a composer.
class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.postId});

  final int postId;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _comment = TextEditingController();
  late Future<(Post, List<Comment>)> _future;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<(Post, List<Comment>)> _load() async {
    final api = ref.read(apiProvider);
    final post = await api.getPost(widget.postId);
    final comments = await api.comments(widget.postId);
    return (post, comments);
  }

  Future<void> _send() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref.read(apiProvider).addComment(widget.postId, text);
      _comment.clear();
      setState(() => _future = _load());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<(Post, List<Comment>)>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Could not load post.\n${snap.error}'));
                }
                final (post, comments) = snap.data!;
                return ListView(
                  children: [
                    ListTile(
                      leading: UserAvatar(
                          name: post.authorName,
                          mediaId: post.authorPhotoId,
                          size: 40,
                          colorSeed: post.authorId),
                      title: Text(post.authorName,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(DateFormat.yMMMd().add_jm().format(post.createdAt.toLocal())),
                    ),
                    if (post.kind == 'image' && post.mediaId != null)
                      AspectRatio(aspectRatio: 1, child: AuthImage(mediaId: post.mediaId!)),
                    if (post.body.isNotEmpty)
                      Padding(padding: const EdgeInsets.all(16), child: Text(post.body)),
                    const Divider(),
                    if (comments.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('No comments yet. Say hi!')),
                      ),
                    ...comments.map((c) => ListTile(
                          leading: UserAvatar(name: c.authorName, mediaId: c.authorPhotoId, size: 32),
                          title: Text(c.authorName,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          subtitle: Text(c.body),
                        )),
                  ],
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _comment,
                      decoration: const InputDecoration(
                        hintText: 'Add a comment…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: _sending
                        ? const SizedBox(
                            height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    onPressed: _sending ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

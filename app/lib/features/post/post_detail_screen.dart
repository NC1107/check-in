import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/auth_image.dart';
import '../../widgets/user_avatar.dart';

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return DateFormat.MMMd().format(dt.toLocal());
}

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
  bool? _likeOverride; // null = use the post's server value

  Future<void> _savePhoto(int mediaId) async {
    try {
      final bytes = await ref.read(apiProvider).downloadMedia(mediaId);
      await Gal.putImageBytes(bytes);
      if (mounted) _snack('Saved to your photos');
    } on GalException catch (_) {
      if (mounted) _snack('Allow photo access to save this');
    } catch (_) {
      if (mounted) _snack('Could not save the photo');
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _toggleLike(Post post) async {
    final current = _likeOverride ?? post.likedByViewer;
    final next = !current;
    setState(() => _likeOverride = next);
    try {
      final api = ref.read(apiProvider);
      next ? await api.like(post.id) : await api.unlike(post.id);
    } catch (_) {
      if (mounted) setState(() => _likeOverride = current);
    }
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<(Post, List<Comment>)> _load() async {
    final api = ref.read(apiProvider);
    final post = await api.getPost(widget.postId);
    final comments = await api.comments(widget.postId);
    return (post, comments);
  }

  Future<void> _send() async {
    final text = _comment.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    FocusScope.of(context).unfocus();
    try {
      await ref.read(apiProvider).addComment(widget.postId, text);
      _comment.clear();
      setState(() => _future = _load());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add comment')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: const Text('Post',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<(Post, List<Comment>)>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: kAccent));
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Could not load post.\n${snap.error}',
                          textAlign: TextAlign.center, style: const TextStyle(color: kFgSecondary)),
                    ),
                  );
                }
                final (post, comments) = snap.data!;
                return ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    _postHeader(post),
                    if (post.location != null && post.location!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Row(
                          children: [
                            const Icon(Icons.place_outlined, size: 14, color: kFgMuted),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(post.location!,
                                  style: const TextStyle(color: kFgMuted, fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                    if (post.body.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                        child: Text(post.body,
                            style: const TextStyle(color: kFgPrimary, fontSize: 15, height: 1.5)),
                      ),
                    if (post.kind == 'image' && post.mediaId != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: AspectRatio(
                            aspectRatio: 4 / 3,
                            child: AuthImage(mediaId: post.mediaId!),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    _actions(post, comments.length),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        comments.isEmpty
                            ? 'Comments'
                            : '${comments.length} ${comments.length == 1 ? 'comment' : 'comments'}',
                        style: const TextStyle(
                            color: kFgMuted, fontWeight: FontWeight.w600, fontSize: 12),
                      ),
                    ),
                    const Divider(color: kBorder, height: 1),
                    if (comments.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 28, 16, 28),
                        child: Center(
                          child:
                              Text('No comments yet. Say hi!', style: TextStyle(color: kFgMuted)),
                        ),
                      )
                    else
                      ...comments.map(_commentRow),
                  ],
                );
              },
            ),
          ),
          _composer(),
        ],
      ),
    );
  }

  /// Like + comment counts under the post, with a tappable (ripple) like button.
  Widget _actions(Post post, int commentCount) {
    final liked = _likeOverride ?? post.likedByViewer;
    final likes = post.likeCount + (liked == post.likedByViewer ? 0 : (liked ? 1 : -1));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkResponse(
              onTap: () => _toggleLike(post),
              radius: 28,
              containedInkWell: true,
              highlightShape: BoxShape.rectangle,
              borderRadius: BorderRadius.circular(9),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(liked ? Icons.favorite : Icons.favorite_border,
                        size: 22, color: liked ? kLike : kFgSecondary),
                    const SizedBox(width: 6),
                    Text('$likes',
                        style: const TextStyle(
                            color: kFgSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.chat_bubble_outline, size: 21, color: kFgSecondary),
                const SizedBox(width: 6),
                Text('$commentCount',
                    style: const TextStyle(
                        color: kFgSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _postHeader(Post post) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Row(
        children: [
          UserAvatar(
              name: post.authorName,
              mediaId: post.authorPhotoId,
              size: 42,
              colorSeed: post.authorId),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(post.authorName,
                    style: const TextStyle(
                        color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 2),
                Text(_relativeTime(post.createdAt),
                    style: const TextStyle(color: kFgMuted, fontSize: 12)),
              ],
            ),
          ),
          if (post.kind == 'image' && post.mediaId != null)
            IconButton(
              icon: const Icon(Icons.download_outlined, size: 22, color: kFgSecondary),
              tooltip: 'Save photo',
              onPressed: () => _savePhoto(post.mediaId!),
            ),
        ],
      ),
    );
  }

  Widget _commentRow(Comment c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(name: c.authorName, mediaId: c.authorPhotoId, size: 32, colorSeed: c.id),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(c.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 13)),
                    ),
                    const SizedBox(width: 8),
                    Text(_relativeTime(c.createdAt),
                        style: const TextStyle(color: kFgMuted, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(c.body,
                    style: const TextStyle(color: kFgSecondary, fontSize: 14, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: kBgMain,
          border: Border(top: BorderSide(color: kBorder)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _comment,
                onSubmitted: (_) => _send(),
                textInputAction: TextInputAction.send,
                style: const TextStyle(color: kFgPrimary, fontSize: 14),
                cursorColor: kAccent,
                decoration: InputDecoration(
                  hintText: 'Add a comment…',
                  hintStyle: const TextStyle(color: kFgMuted),
                  filled: true,
                  fillColor: kBgSurface,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9999),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9999),
                    borderSide: const BorderSide(color: kAccent),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _comment,
              builder: (_, val, __) {
                final canSend = val.text.trim().isNotEmpty && !_sending;
                return IconButton(
                  onPressed: canSend ? _send : null,
                  icon: _sending
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: kAccent))
                      : Icon(Icons.arrow_upward_rounded, color: canSend ? kAccent : kFgMuted),
                  style: IconButton.styleFrom(
                    backgroundColor: canSend ? kAccentLight : kBgSurface,
                    shape: const CircleBorder(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

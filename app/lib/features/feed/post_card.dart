import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../widgets/auth_image.dart';
import '../post/post_detail_screen.dart';

// Design tokens matching the Check-In design system
const _bgSurface = Color(0xFF1C1C1E);
const _border = Color(0xFF27272A);
const _fgPrimary = Color(0xFFEDEDEF);
const _fgSecondary = Color(0xFFABABB0);
const _fgMuted = Color(0xFF848490);
const _accent = Color(0xFF5557E0);
const _like = Color(0xFFEF4444);

const _avatarPalette = [
  Color(0xFF5557E0), Color(0xFF13AF9D), Color(0xFFDD1C85),
  Color(0xFFE9960A), Color(0xFF8458E9), Color(0xFF22C55E),
  Color(0xFFEF4444), Color(0xFF3B82F6),
];

Color _avatarColor(int id) => _avatarPalette[id.abs() % _avatarPalette.length];

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  return '${diff.inDays}d';
}

/// Circular avatar widget with the author's initial and a consistent color.
class AuthorAvatar extends StatelessWidget {
  const AuthorAvatar({
    super.key,
    required this.userId,
    required this.name,
    required this.size,
  });

  final int userId;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _avatarColor(userId),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.39,
          height: 1,
        ),
      ),
    );
  }
}

/// PostCard renders one post in the feed with the design-system dark card style.
class PostCard extends ConsumerStatefulWidget {
  const PostCard({super.key, required this.post});

  final Post post;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  late bool _liked = widget.post.likedByViewer;
  late int _likes = widget.post.likeCount;
  final _commentCtrl = TextEditingController();
  bool _postingComment = false;

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _toggleLike() async {
    final api = ref.read(apiProvider);
    setState(() {
      _liked = !_liked;
      _likes += _liked ? 1 : -1;
    });
    try {
      _liked ? await api.like(widget.post.id) : await api.unlike(widget.post.id);
    } catch (_) {
      setState(() {
        _liked = !_liked;
        _likes += _liked ? 1 : -1;
      });
    }
  }

  Future<void> _addComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty || _postingComment) return;
    setState(() => _postingComment = true);
    try {
      await ref.read(apiProvider).addComment(widget.post.id, text);
      _commentCtrl.clear();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _postingComment = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final me = ref.watch(sessionProvider).user;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _bgSurface,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Row(
              children: [
                AuthorAvatar(userId: p.authorId, name: p.authorName, size: 38),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.authorName,
                    style: const TextStyle(
                      color: _fgPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                Text(
                  _relativeTime(p.createdAt),
                  style: const TextStyle(color: _fgMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          // Caption
          if (p.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Text(
                p.body,
                style: const TextStyle(color: _fgPrimary, fontSize: 15, height: 1.5),
              ),
            )
          else
            const SizedBox(height: 10),
          // Image
          if (p.kind == 'image' && p.mediaId != null)
            AspectRatio(
              aspectRatio: 4 / 3,
              child: AuthImage(mediaId: p.mediaId!),
            ),
          // Actions row
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleLike,
                  child: Row(
                    children: [
                      Icon(
                        _liked ? Icons.favorite : Icons.favorite_border,
                        size: 22,
                        color: _liked ? _like : _fgSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$_likes',
                        style: const TextStyle(
                          color: _fgSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PostDetailScreen(postId: p.id),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.chat_bubble_outline, size: 21, color: _fgSecondary),
                      const SizedBox(width: 6),
                      Text(
                        '${p.commentCount}',
                        style: const TextStyle(
                          color: _fgSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Quick comment input
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _border)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 11),
            child: Row(
              children: [
                if (me != null)
                  AuthorAvatar(userId: me.id, name: me.name, size: 26),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    controller: _commentCtrl,
                    onSubmitted: (_) => _addComment(),
                    style: const TextStyle(color: _fgPrimary, fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'Add a comment…',
                      hintStyle: TextStyle(color: _fgMuted),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _commentCtrl,
                  builder: (_, val, __) {
                    final canPost = val.text.trim().isNotEmpty;
                    return TextButton(
                      onPressed: canPost ? _addComment : null,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'Post',
                        style: TextStyle(
                          color: canPost ? _accent : _fgMuted,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

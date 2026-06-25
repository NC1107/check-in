import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/auth_image.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail_screen.dart';

// Theme tokens (centralized in theme/tokens.dart).
const _bgSurface = kBgSurface;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;
const _accent = kAccent;
const _like = kLike;

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  return '${diff.inDays}d';
}

/// PostCard renders one post in the feed with the design-system dark card style.
class PostCard extends ConsumerStatefulWidget {
  const PostCard({super.key, required this.post, this.onDeleted});

  final Post post;

  /// Called after this post is deleted so the host list (feed/profile) can refresh.
  final VoidCallback? onDeleted;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  late bool _liked = widget.post.likedByViewer;
  late int _likes = widget.post.likeCount;
  late int _comments = widget.post.commentCount;
  final _commentCtrl = TextEditingController();
  bool _postingComment = false;

  // If this State gets re-bound to a different post (e.g. the list shifts when a new
  // post is prepended), resync the like/comment state so counts don't bleed between
  // posts. A ValueKey on each card normally prevents this; this is a safety net.
  @override
  void didUpdateWidget(PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id) {
      _liked = widget.post.likedByViewer;
      _likes = widget.post.likeCount;
      _comments = widget.post.commentCount;
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bgSurface,
        title: const Text('Delete this check-in?', style: TextStyle(color: _fgPrimary)),
        content: const Text('This permanently removes the post for everyone.',
            style: TextStyle(color: _fgSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _fgSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: _like, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).deletePost(widget.post.id);
      ref.invalidate(feedProvider); // drop it from the feed immediately
      widget.onDeleted?.call();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not delete the post')));
      }
    }
  }

  /// Downloads the post's photo (with auth) and saves it to the device gallery.
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
    FocusScope.of(context).unfocus(); // close the keyboard
    try {
      await ref.read(apiProvider).addComment(widget.post.id, text);
      _commentCtrl.clear();
      if (mounted) setState(() => _comments++);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add comment')),
        );
      }
    } finally {
      if (mounted) setState(() => _postingComment = false);
    }
  }

  /// One tappable feed action (like / comment) with a Material ripple so presses give
  /// clear visual feedback.
  Widget _action({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: iconColor),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      color: _fgSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
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
                UserAvatar(
                    name: p.authorName, size: 38, mediaId: p.authorPhotoId, colorSeed: p.authorId),
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
                // ⋯ menu: Save photo on any image post; Delete only for the author.
                if ((me != null && me.id == p.authorId) || (p.kind == 'image' && p.mediaId != null))
                  SizedBox(
                    height: 30,
                    width: 30,
                    child: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz, size: 20, color: _fgMuted),
                      padding: EdgeInsets.zero,
                      color: _bgSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: _border),
                      ),
                      onSelected: (v) {
                        if (v == 'delete') _confirmDelete();
                        if (v == 'save') _savePhoto(p.mediaId!);
                      },
                      itemBuilder: (_) => [
                        if (p.kind == 'image' && p.mediaId != null)
                          const PopupMenuItem(
                            value: 'save',
                            child: Row(
                              children: [
                                Icon(Icons.download_outlined, size: 19, color: _fgPrimary),
                                SizedBox(width: 10),
                                Text('Save photo', style: TextStyle(color: _fgPrimary)),
                              ],
                            ),
                          ),
                        if (me != null && me.id == p.authorId)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline, size: 19, color: _like),
                                SizedBox(width: 10),
                                Text('Delete', style: TextStyle(color: _like)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          // Location (from the photo), under the header
          if (p.location != null && p.location!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
              child: Row(
                children: [
                  const Icon(Icons.place_outlined, size: 13, color: _fgMuted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(p.location!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _fgMuted, fontSize: 12)),
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
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                _action(
                  icon: _liked ? Icons.favorite : Icons.favorite_border,
                  iconColor: _liked ? _like : _fgSecondary,
                  label: '$_likes',
                  onTap: _toggleLike,
                ),
                _action(
                  icon: Icons.chat_bubble_outline,
                  iconColor: _fgSecondary,
                  label: '$_comments',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => PostDetailScreen(postId: p.id)),
                  ),
                ),
              ],
            ),
          ),
          // Recent comments preview (inline, so you don't have to open the post)
          if (p.commentsPreview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_comments > p.commentsPreview.length)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PostDetailScreen(postId: p.id),
                      )),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('View all $_comments comments',
                            style: const TextStyle(color: _fgMuted, fontSize: 13)),
                      ),
                    ),
                  ...p.commentsPreview.map((c) => Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: RichText(
                          text: TextSpan(children: [
                            TextSpan(
                                text: '${c.authorName} ',
                                style: const TextStyle(
                                    color: _fgPrimary, fontWeight: FontWeight.w600, fontSize: 13)),
                            TextSpan(
                                text: c.body,
                                style: const TextStyle(
                                    color: _fgSecondary, fontSize: 13, height: 1.3)),
                          ]),
                        ),
                      )),
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
                  UserAvatar(name: me.name, size: 26, mediaId: me.profileMediaId, colorSeed: me.id),
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

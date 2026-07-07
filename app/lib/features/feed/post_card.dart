import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/post_image_carousel.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail_screen.dart';

// Report reasons shown in the bottom sheet.
const _reportReasons = [
  'Inappropriate or offensive content',
  'Harassment or bullying',
  'Spam',
  'False information',
  'Other',
];

// Theme tokens (centralized in theme/tokens.dart).
const _bgSurface = kBgSurface;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;
const _like = kLike;

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  return '${diff.inDays}d';
}

/// The exact local date + time, for the long-press tooltip on a relative timestamp.
String fullLocalTime(DateTime dt) => DateFormat('MMM d, y · h:mm a').format(dt.toLocal());

/// Bottom sheet letting the user pick a reason before submitting a report. Pops the
/// selected reason string, or null when dismissed.
class _ReportSheet extends StatelessWidget {
  const _ReportSheet();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Report this post',
                style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('The admin will review your report within 24 hours.',
                style: TextStyle(color: _fgMuted, fontSize: 13)),
          ),
        ),
        const Divider(color: _border, height: 1),
        ..._reportReasons.map(
          (r) => ListTile(
            title: Text(r, style: const TextStyle(color: _fgPrimary, fontSize: 15)),
            // No chevron: tapping a reason submits the report, it doesn't drill in.
            onTap: () => Navigator.of(context).pop(r),
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
      ],
    );
  }
}

/// PostCard renders one post in the feed with the design-system dark card style.
///
/// Every server call (like, comment, report, delete, media) is routed to the post's
/// origin group (post.groupId), so cards from different groups work side by side in
/// the combined All view.
class PostCard extends ConsumerStatefulWidget {
  const PostCard({super.key, required this.post, this.onDeleted, this.groupColor});

  final Post post;

  /// Called after this post is deleted so the host list (feed/profile) can refresh.
  final VoidCallback? onDeleted;

  /// The origin group's color, set only in the merged (multi-group) feed. When non-null
  /// the author's avatar wears a thin ring in this color so groups are told apart; null
  /// in a single-group view, where no group marker appears.
  final Color? groupColor;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> with TickerProviderStateMixin {
  late bool _liked = widget.post.likedByViewer;
  late int _likes = widget.post.likeCount;
  late int _comments = widget.post.commentCount;
  final _commentCtrl = TextEditingController();
  bool _postingComment = false;
  // Comments added inline on this card since it was built, shown immediately so the
  // typed text doesn't appear to vanish (the post's own preview is immutable).
  final List<CommentPreview> _added = [];

  // A quick pop on the heart when a like lands, and a bigger burst over the photo on a
  // double-tap-to-like.
  late final AnimationController _likePop =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  late final AnimationController _burst =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 520));

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
      _added.clear();
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    _likePop.dispose();
    _burst.dispose();
    super.dispose();
  }

  Future<void> _reportPost() async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const _ReportSheet(),
    );
    if (reason == null || !mounted) return;
    try {
      await ref.read(contentApiProvider(widget.post.groupId)).reportPost(widget.post.id, reason);
      if (mounted) _snack('Report sent. The admin will review it.');
    } catch (_) {
      if (mounted) _snack('Could not send report. Try again.');
    }
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
    HapticFeedback.mediumImpact();
    try {
      await ref.read(contentApiProvider(widget.post.groupId)).deletePost(widget.post.id);
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
      final bytes = await ref.read(contentApiProvider(widget.post.groupId)).downloadMedia(mediaId);
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
    HapticFeedback.lightImpact();
    final api = ref.read(contentApiProvider(widget.post.groupId));
    setState(() {
      _liked = !_liked;
      _likes += _liked ? 1 : -1;
    });
    if (_liked) _likePop.forward(from: 0);
    try {
      _liked ? await api.like(widget.post.id) : await api.unlike(widget.post.id);
    } catch (_) {
      setState(() {
        _liked = !_liked;
        _likes += _liked ? 1 : -1;
      });
    }
  }

  /// Double-tapping the photo likes it (never unlikes) and plays the heart burst.
  void _doubleTapLike() {
    if (!_liked) {
      _toggleLike();
    } else {
      HapticFeedback.lightImpact();
    }
    _burst.forward(from: 0);
  }

  Future<void> _addComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty || _postingComment) return;
    setState(() => _postingComment = true);
    FocusScope.of(context).unfocus(); // close the keyboard
    try {
      final comment =
          await ref.read(contentApiProvider(widget.post.groupId)).addComment(widget.post.id, text);
      _commentCtrl.clear();
      if (mounted) {
        setState(() {
          _comments++;
          _added.add(CommentPreview(authorName: comment.authorName, body: comment.body));
        });
      }
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
    required String semantic,
    required VoidCallback onTap,
    Listenable? bump,
  }) {
    Widget iconWidget = Icon(icon, size: 22, color: iconColor);
    if (bump != null) {
      iconWidget = AnimatedBuilder(
        animation: bump,
        builder: (_, child) {
          final t = (bump as Animation<double>).value;
          return Transform.scale(scale: 1 + 0.35 * math.sin(math.pi * t), child: child);
        },
        child: iconWidget,
      );
    }
    return Semantics(
      button: true,
      label: semantic,
      value: label,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          onTap: onTap,
          radius: 28,
          containedInkWell: true,
          highlightShape: BoxShape.rectangle,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            // Vertical 11 keeps the row at the 44px minimum tap target.
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                iconWidget,
                const SizedBox(width: 6),
                Text(label,
                    style: const TextStyle(
                        color: _fgSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final account = ref.watch(contentAccountProvider(p.groupId));
    final me = account?.user;

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
                // In the merged view the avatar wears a thin ring in the origin
                // group's color - the group marker for the whole card.
                if (widget.groupColor != null)
                  Semantics(
                    label: account != null ? 'Group: ${account.displayName}' : 'Group',
                    // The avatar is decorative here (the author's name sits beside it);
                    // announce only the group the ring encodes.
                    excludeSemantics: true,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: widget.groupColor!, width: 2),
                      ),
                      child: UserAvatar(
                          name: p.authorName,
                          size: 34,
                          mediaId: p.authorPhotoId,
                          colorSeed: p.authorId,
                          groupId: p.groupId),
                    ),
                  )
                else
                  UserAvatar(
                      name: p.authorName,
                      size: 38,
                      mediaId: p.authorPhotoId,
                      colorSeed: p.authorId,
                      groupId: p.groupId),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.authorName,
                        style: const TextStyle(
                          color: _fgPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      if (p.people.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            p.peopleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _fgMuted, fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
                Tooltip(
                  message: fullLocalTime(p.createdAt),
                  child: Semantics(
                    label: fullLocalTime(p.createdAt),
                    excludeSemantics: true,
                    child: Text(
                      _relativeTime(p.createdAt),
                      style: const TextStyle(color: _fgMuted, fontSize: 12),
                    ),
                  ),
                ),
                // ⋯ menu: always shown. Save photo on image posts; Report for others;
                // Delete only for the author.
                SizedBox(
                  height: 44,
                  width: 44,
                  child: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, size: 20, color: _fgMuted),
                    tooltip: 'Post options',
                    padding: EdgeInsets.zero,
                    color: _bgSurface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: _border),
                    ),
                    onSelected: (v) {
                      if (v == 'delete') _confirmDelete();
                      if (v == 'save') _savePhoto(p.mediaId!);
                      if (v == 'report') _reportPost();
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
                      if (me != null && me.id != p.authorId)
                        const PopupMenuItem(
                          value: 'report',
                          child: Row(
                            children: [
                              Icon(Icons.flag_outlined, size: 19, color: _fgPrimary),
                              SizedBox(width: 10),
                              Text('Report', style: TextStyle(color: _fgPrimary)),
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
          // Image(s) - the carousel sizes itself (single images keep their own
          // clamped aspect ratio); the heart burst overlays it.
          if (p.kind == 'image' && p.images.isNotEmpty)
            GestureDetector(
              onDoubleTap: _doubleTapLike,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PostImageCarousel(mediaIds: p.images, groupId: p.groupId),
                  Positioned.fill(
                    child: IgnorePointer(child: Center(child: _HeartBurst(_burst))),
                  ),
                ],
              ),
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
                  semantic: _liked ? 'Unlike' : 'Like',
                  bump: _likePop,
                  onTap: _toggleLike,
                ),
                _action(
                  icon: Icons.chat_bubble_outline,
                  iconColor: _fgSecondary,
                  label: '$_comments',
                  semantic: 'Comments',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => PostDetailScreen(postId: p.id, groupId: p.groupId)),
                  ),
                ),
              ],
            ),
          ),
          // Recent comments preview (inline, so you don't have to open the post)
          if (p.commentsPreview.isNotEmpty || _added.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_comments > p.commentsPreview.length + _added.length)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PostDetailScreen(postId: p.id, groupId: p.groupId),
                      )),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('View all $_comments comments',
                            style: const TextStyle(color: _fgMuted, fontSize: 13)),
                      ),
                    ),
                  ...[...p.commentsPreview, ..._added].map((c) => Padding(
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
                  UserAvatar(
                      name: me.name,
                      size: 26,
                      mediaId: me.profileMediaId,
                      colorSeed: me.id,
                      groupId: p.groupId),
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
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(44, 44),
                      ),
                      child: Text(
                        'Post',
                        style: TextStyle(
                          color: canPost ? context.accent : _fgMuted,
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

/// The big white heart that pops over a photo on double-tap-to-like: scales up with an
/// overshoot, holds, then fades. Invisible at rest (controller value 0).
class _HeartBurst extends StatelessWidget {
  const _HeartBurst(this.controller);

  final Animation<double> controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = controller.value;
        if (t == 0) return const SizedBox.shrink();
        final scale = 0.5 + 0.9 * Curves.easeOutBack.transform(t.clamp(0.0, 1.0));
        final opacity = t < 0.55 ? 1.0 : (1 - (t - 0.55) / 0.45).clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Icon(
              Icons.favorite,
              color: Colors.white.withValues(alpha: 0.92),
              size: 92,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 18)],
            ),
          ),
        );
      },
    );
  }
}

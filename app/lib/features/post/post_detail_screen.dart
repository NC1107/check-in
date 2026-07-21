import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/likers_sheet.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/post_image_carousel.dart';
import '../../widgets/tagged_people_line.dart';
import '../../widgets/user_avatar.dart';
import '../profile/profile_screen.dart';

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return DateFormat.MMMd().format(dt.toLocal());
}

/// The exact local date + time, for the long-press tooltip on a relative timestamp.
String _fullLocalTime(DateTime dt) => DateFormat('MMM d, y · h:mm a').format(dt.toLocal());

/// PostDetailScreen shows a single post with its full comment thread and a composer.
/// [groupId] is the connected group the post lives on (null = the current group);
/// every call from this screen goes to that server.
class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({
    super.key,
    required this.postId,
    this.groupId,
    this.focusComments = false,
    this.copies,
  });

  final int postId;
  final String? groupId;

  /// When true (e.g. opened from a "commented on your check-in" notification), the view
  /// scrolls straight to the comment thread once it loads instead of landing on the post.
  final bool focusComments;

  /// The copies of a collapsed cross-post (one per group the viewer can see it in). When
  /// set, the thread merges every group's comments and likers, each tagged with its group,
  /// and a new comment is posted to a group the viewer picks. Null for an ordinary post.
  final List<PostCopy>? copies;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _comment = TextEditingController();
  final _commentFocus = FocusNode();
  final _scroll = ScrollController();
  final _commentsKey = GlobalKey();
  // Loaded post + thread held in state so sending a comment appends to the list in place
  // instead of re-fetching the whole screen (which blanked to a spinner and flashed).
  Post? _post;
  List<Comment> _comments = [];
  bool _loading = true;
  Object? _error;
  bool _sending = false;
  bool _didFocusComments = false;
  // Cross-post only: which group a new comment posts to (defaults to the first copy). Like
  // state is read from the app-wide likesProvider, so it stays in step with the feed card.
  String? _composeGroupId;
  // The comment being replied to, or null for a top-level comment. A reply always goes to
  // the parent's own group, so replying pins the compose target to it.
  Comment? _replyTo;

  bool get _isCrossPost => (widget.copies?.length ?? 0) > 1;

  /// Starts a reply to [c]: pins the compose group to the parent's (so it lands on the right
  /// server) and focuses the field. Tapping "Reply" on another comment just re-targets.
  void _startReply(Comment c) {
    setState(() {
      _replyTo = c;
      if (_isCrossPost && c.groupId != null) _composeGroupId = c.groupId;
    });
    _commentFocus.requestFocus();
  }

  void _cancelReply() => setState(() => _replyTo = null);

  /// The display name of the comment [c] is replying to, resolved from the loaded thread
  /// (same id, and same group for a merged cross-post thread). Null if it can't be found.
  String? _parentAuthorName(Comment c) {
    final pid = c.parentCommentId;
    if (pid == null) return null;
    for (final other in _comments) {
      if (other.id == pid && other.groupId == c.groupId) return other.authorName;
    }
    return null;
  }

  Future<void> _savePhoto(int mediaId) async {
    try {
      final bytes = await ref.read(contentApiProvider(widget.groupId)).downloadMedia(mediaId);
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

  /// Toggles the like through the shared likesProvider so the feed card and this screen
  /// always agree. A cross-post's one heart brings every copy to the same state.
  void _toggleLike(Post post) {
    final overlay = ref.read(likesProvider);
    final want = !likeView(post, overlay).liked;
    final likes = ref.read(likesProvider.notifier);
    final copies = widget.copies;
    if (_isCrossPost && copies != null) {
      for (final c in copies) {
        final cur = overlay['${c.groupId}:${c.postId}'] ?? c.likedByViewer;
        if (cur != want) likes.setLiked(c.groupId, c.postId, want);
      }
    } else {
      likes.setLiked(widget.groupId, post.id, want);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    _commentFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// After the thread loads from a comment notification, bring the comments into view so the
  /// user lands on the reply rather than the top of the post. Runs once.
  void _maybeFocusComments() {
    if (!widget.focusComments || _didFocusComments) return;
    _didFocusComments = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _commentsKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(contentApiProvider(widget.groupId));
      var post = await api.getPost(widget.postId);
      final List<Comment> comments;
      final copies = widget.copies;
      if (_isCrossPost && copies != null) {
        // Merge each group's own thread, tagging every comment with its group. Only groups
        // the viewer can reach contribute, so a single-group member never sees the others.
        final lists = await Future.wait([
          for (final c in copies)
            ref
                .read(contentApiProvider(c.groupId))
                .comments(c.postId)
                .then((cs) => [for (final cm in cs) cm.withGroup(c.groupId)])
                .catchError((_) => <Comment>[]),
        ]);
        comments = [for (final l in lists) ...l]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        post = post.withCopies(copies);
        _composeGroupId ??= copies.first.groupId;
      } else {
        comments = await api.comments(widget.postId);
        // Tag the post with its group so the like overlay keys it the same way the feed
        // card does (getPost doesn't stamp the origin group itself).
        if (widget.groupId != null) post = post.withGroup(widget.groupId!);
      }
      if (!mounted) return;
      setState(() {
        _post = post;
        _comments = comments;
        _loading = false;
      });
      _maybeFocusComments();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _send() async {
    final text = _comment.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    FocusScope.of(context).unfocus();
    // On a cross-post, a comment goes to exactly one group - the one the viewer picked. The
    // members of the other groups never see it; only the poster, who is in every group, does.
    // A reply is pinned to its parent's group (see _startReply), so the parent id it carries
    // always refers to a comment on the same server.
    final target = _sendTarget();
    final replyToId = _replyTo?.id;
    try {
      final added = (await ref
              .read(contentApiProvider(target.groupId))
              .addComment(target.postId, text, parentCommentId: replyToId))
          .withGroup(_isCrossPost ? target.groupId : null);
      _comment.clear();
      // Append in place - no re-fetch, so the post and existing comments don't flash.
      if (mounted) {
        setState(() {
          _comments = [..._comments, added];
          _replyTo = null;
        });
      }
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

  /// Where a new comment is sent: the picked group's copy for a cross-post, else the post
  /// itself. Falls back to the representative if the picked group somehow isn't a copy.
  ({int postId, String? groupId}) _sendTarget() {
    final copies = widget.copies;
    if (_isCrossPost && copies != null) {
      for (final c in copies) {
        if (c.groupId == _composeGroupId) return (postId: c.postId, groupId: c.groupId);
      }
      final first = copies.first;
      return (postId: first.postId, groupId: first.groupId);
    }
    return (postId: widget.postId, groupId: widget.groupId);
  }

  ServerAccount? _account(String? groupId) {
    if (groupId == null) return null;
    for (final a in ref.read(multiSessionProvider).signedIn) {
      if (a.id == groupId) return a;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        toolbarHeight: 44, // iOS-native nav height - trims the bulky default 56
        titleSpacing: 0,
        title: const Text('Post',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 17)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Builder(
              builder: (context) {
                if (_loading) {
                  return Center(child: CircularProgressIndicator(color: context.accent));
                }
                if (_error != null || _post == null) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Could not load check-in.',
                              textAlign: TextAlign.center, style: TextStyle(color: kFgSecondary)),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _load,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final post = _post!;
                final comments = _comments;
                return ListView(
                  controller: _scroll,
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
                    if (post.kind == 'image' && post.images.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: AspectRatio(
                            aspectRatio: 4 / 3,
                            child: PostImageCarousel(
                              mediaIds: post.images,
                              groupId: widget.groupId,
                              onImageTap: (mediaId) => PhotoViewerScreen.open(
                                context,
                                mediaIds: post.images,
                                initialIndex:
                                    post.images.indexOf(mediaId).clamp(0, post.images.length - 1),
                                groupId: widget.groupId,
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    _actions(post, comments.length),
                    const SizedBox(height: 8),
                    Padding(
                      key: _commentsKey,
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
    final view = likeView(post, ref.watch(likesProvider));
    final liked = view.liked;
    final likes = view.likes;
    final me = ref.read(contentAccountProvider(widget.groupId))?.user;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkResponse(
              onTap: () => _toggleLike(post),
              // The author can long-press their own post's like to see who liked it -
              // merged across groups for a cross-post.
              onLongPress: (me != null && me.id == post.authorId)
                  ? () => _isCrossPost
                      ? showLikersSheet(context, copies: widget.copies)
                      : showLikersSheet(context, postId: post.id, groupId: widget.groupId)
                  : null,
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

  /// Opens a member's profile in this post's group (no-op for a missing id).
  void _openProfile(int userId) => _openProfileIn(userId, widget.groupId);

  /// Opens a member's profile on a specific group's server (for merged-thread
  /// commenters) - the viewer's own editable profile if it's their own account,
  /// otherwise a read-only view.
  void _openProfileIn(int userId, String? groupId) {
    if (userId <= 0) return;
    final screen = ProfileScreen.resolve(context, userId: userId, groupId: groupId);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// A small "· Family" pill in the origin group's color, shown on merged-thread comments
  /// so the poster can tell which group each comment came from.
  Widget _groupBadge(String? groupId) {
    final acct = _account(groupId);
    if (acct == null) return const SizedBox.shrink();
    final color = acct.displayColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.16), kBgMain),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Text(acct.displayName,
              style: const TextStyle(color: kFgMuted, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Which group a new comment goes to on a cross-post: a row of selectable group chips.
  Widget _groupPicker(List<PostCopy> copies) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Row(
        children: [
          const Text('To', style: TextStyle(color: kFgMuted, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [for (final c in copies) _groupChip(c.groupId)]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupChip(String groupId) {
    final acct = _account(groupId);
    final selected = _composeGroupId == groupId;
    final color = acct?.displayColor ?? context.accent;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => setState(() => _composeGroupId = groupId),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Color.alphaBlend(color.withValues(alpha: 0.20), kBgMain) : kBgSurface,
            border: Border.all(color: selected ? color : kBorder),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              Text(acct?.displayName ?? 'Group',
                  style: TextStyle(
                      color: selected ? kFgPrimary : kFgSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _postHeader(Post post) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _openProfile(post.authorId),
            child: UserAvatar(
                name: post.authorName,
                mediaId: post.authorPhotoId,
                size: 42,
                colorSeed: post.authorId,
                groupId: widget.groupId),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => _openProfile(post.authorId),
                  behavior: HitTestBehavior.opaque,
                  child: Text(post.authorName,
                      style: const TextStyle(
                          color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                if (post.people.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: TaggedPeopleLine(
                      people: post.people,
                      groupId: widget.groupId,
                      style: const TextStyle(color: kFgMuted, fontSize: 12.5),
                    ),
                  ),
                const SizedBox(height: 2),
                Tooltip(
                  message: _fullLocalTime(post.createdAt),
                  child: Semantics(
                    label: _fullLocalTime(post.createdAt),
                    excludeSemantics: true,
                    child: Text(_relativeTime(post.createdAt),
                        style: const TextStyle(color: kFgMuted, fontSize: 12)),
                  ),
                ),
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
    // A merged comment opens the commenter's profile on its own group's server.
    final gid = c.groupId ?? widget.groupId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => _openProfileIn(c.authorId, gid),
            child: UserAvatar(
                name: c.authorName,
                mediaId: c.authorPhotoId,
                size: 32,
                colorSeed: c.id,
                groupId: gid),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onTap: () => _openProfileIn(c.authorId, gid),
                        behavior: HitTestBehavior.opaque,
                        child: Text(c.authorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: _fullLocalTime(c.createdAt),
                      child: Semantics(
                        label: _fullLocalTime(c.createdAt),
                        excludeSemantics: true,
                        child: Text(_relativeTime(c.createdAt),
                            style: const TextStyle(color: kFgMuted, fontSize: 11)),
                      ),
                    ),
                    if (_isCrossPost && c.groupId != null) ...[
                      const SizedBox(width: 8),
                      _groupBadge(c.groupId),
                    ],
                  ],
                ),
                if (_parentAuthorName(c) case final parent?) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(Icons.subdirectory_arrow_right, size: 13, color: kFgMuted),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text('Replying to $parent',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kFgMuted, fontSize: 11.5)),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 2),
                Text(c.body,
                    style: const TextStyle(color: kFgSecondary, fontSize: 14, height: 1.35)),
                const SizedBox(height: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _startReply(c),
                  child: const Text('Reply',
                      style: TextStyle(color: kFgMuted, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_replyTo case final r?) _replyBanner(r),
            // Cross-post: a comment goes to exactly one group. Let the poster pick which -
            // the others never see it. Defaults to the first group shared to. While replying
            // the group is pinned to the parent's, so the picker is hidden.
            if (_isCrossPost && widget.copies != null && _replyTo == null)
              _groupPicker(widget.copies!),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _comment,
                    focusNode: _commentFocus,
                    onSubmitted: (_) => _send(),
                    textInputAction: TextInputAction.send,
                    style: const TextStyle(color: kFgPrimary, fontSize: 14),
                    cursorColor: context.accent,
                    decoration: InputDecoration(
                      hintText:
                          _replyTo != null ? 'Reply to ${_replyTo!.authorName}…' : 'Add a comment…',
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
                        borderSide: BorderSide(color: context.accent),
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
                          ? SizedBox(
                              height: 18,
                              width: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2, color: context.accent))
                          : Icon(Icons.arrow_upward_rounded,
                              color: canSend ? context.accent : kFgMuted),
                      style: IconButton.styleFrom(
                        backgroundColor: canSend ? context.accentLight : kBgSurface,
                        shape: const CircleBorder(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The "Replying to X ✕" strip shown above the field while composing a reply.
  Widget _replyBanner(Comment c) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2),
        child: Row(
          children: [
            const Icon(Icons.reply, size: 15, color: kFgMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Replying to ${c.authorName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kFgSecondary, fontSize: 13)),
            ),
            GestureDetector(
              onTap: _cancelReply,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 16, color: kFgMuted),
              ),
            ),
          ],
        ),
      );
}

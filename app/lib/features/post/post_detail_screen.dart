import 'dart:async';
import 'dart:io';

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../notifications/notification_route.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/auth_image.dart';
import '../../widgets/gif_picker.dart';
import '../../widgets/likers_sheet.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/post_image_carousel.dart';
import '../../widgets/report_sheet.dart';
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

/// Whether the comment composer may offer the gif picker for [account]'s server: it has to
/// be able to search gifs at all, and to accept a `mediaId` on a comment. An older server
/// predates the field entirely and would 400 on it (DisallowUnknownFields) - see
/// [ServerInfo.commentMedia] - so both must be true, not just gifSearch.
bool commentGifAllowed(ServerAccount? account) =>
    account != null && account.gifSearch && account.commentMedia;

/// PostDetailScreen shows a single post with its full comment thread and a composer.
/// [groupId] is the connected group the post lives on (null = the current group);
/// every call from this screen goes to that server.
class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({
    super.key,
    required this.postId,
    this.groupId,
    this.focusComments = false,
    this.highlightCommentId,
    this.copies,
    this.gifDownloader,
  });

  final int postId;
  final String? groupId;

  /// When true (e.g. opened from a "commented on your check-in" notification), the view
  /// scrolls straight to the comment thread once it loads instead of landing on the post.
  ///
  /// This is the fallback for a notification that names no particular comment - an older
  /// server that predates [highlightCommentId], or a like. Prefer that when there is one.
  final bool focusComments;

  /// The comment a notification was about: the view scrolls to it and flashes it, so the
  /// member lands on the reply they were told about rather than at the top of the thread.
  /// Null when the notification was about the post itself.
  final int? highlightCommentId;

  /// The copies of a collapsed cross-post (one per group the viewer can see it in). When
  /// set, the thread merges every group's comments and likers, each tagged with its group,
  /// and a new comment is posted to a group the viewer picks. Null for an ordinary post.
  final List<PostCopy>? copies;

  /// Fetches a chosen gif's bytes ahead of re-upload. Defaults to
  /// [ApiClient.downloadExternalGif] (a real fetch from Klipy's CDN); overridable so a
  /// widget test can drive the attach flow without a network.
  final Future<List<int>> Function(String url)? gifDownloader;

  /// The route a notification's target opens, whether the member tapped the notification
  /// itself or found it later in the activity list. Shared so the two land in exactly the
  /// same place; how the route is STACKED is deliberately left to the caller, because a
  /// push should replace the last one it opened while the activity list should push on top
  /// of itself so back returns to the list.
  static Route<void> routeForNotification(NotificationRoute route) => MaterialPageRoute<void>(
        builder: (_) => PostDetailScreen(
          postId: route.postId,
          groupId: route.groupId,
          highlightCommentId: route.commentId,
          focusComments: route.focusComments,
        ),
      );

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

/// A fresh opaque id tying the copies of one comment together across servers.
///
/// Random rather than derived from the content: two members could legitimately say the same
/// word at the same moment, and collapsing those into one comment would delete someone's
/// contribution. 128 bits from a secure source makes an accidental collision impossible in
/// practice, which matters because a collision here would silently hide a real comment.
String _newCrossCommentId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _comment = TextEditingController();
  final _commentFocus = FocusNode();
  final _scroll = ScrollController();
  final _commentsKey = GlobalKey();

  /// One key per comment row, so the thread can be scrolled to a particular one.
  ///
  /// Keyed by group AND id, never by id alone: comment ids are only unique per server, so a
  /// merged cross-post thread can hold two different comments both numbered 1, and handing
  /// them the same GlobalKey is a framework error rather than a cosmetic clash.
  ///
  /// A key only has a context once its row is actually built, and a ListView builds only
  /// what is near the viewport even when every child widget is passed to it up front. A
  /// comment far down a long thread therefore has no context to scroll to on the first
  /// frame - which is exactly the case that matters, since a short thread needs no
  /// scrolling at all. _scrollToRow walks the list down until the row exists.
  final _commentKeys = <String, GlobalKey>{};
  // Loaded post + thread held in state so sending a comment appends to the list in place
  // instead of re-fetching the whole screen (which blanked to a spinner and flashed).
  Post? _post;
  List<Comment> _comments = [];
  bool _loading = true;
  Object? _error;
  bool _sending = false;
  bool _didFocusComments = false;

  /// The row currently flashing (a _rowKeyFor value), cleared once the highlight has
  /// faded. Held in state rather than driven by an animation so it can simply stop.
  String? _highlighted;

  /// The one comment showing its Reply and Report controls, or null when none is.
  ///
  /// A thread is read far more often than it is acted on, so the controls stay out of it
  /// until a comment is tapped. Only one at a time: tapping another moves them, so a thread
  /// cannot end up full of chrome again.
  String? _openActions;
  Timer? _highlightTimer;
  // Cross-post only: which group a new comment posts to (defaults to the first copy). Like
  // state is read from the app-wide likesProvider, so it stays in step with the feed card.
  /// Which group a new comment goes to, or null for "every group holding a copy".
  ///
  /// Null is the default on a cross-post: the check-in itself went to all of them, so a
  /// reply to it going to one by default was the odd half of that pair.
  String? _composeGroupId;

  /// A picked gif held as its own bytes rather than an uploaded media id.
  ///
  /// Media ids are only unique per server, so one cannot describe an attachment on three of
  /// them. Holding the bytes and uploading per target at send time is what lets a gif go to
  /// every group at once - and it also removes the old hazard where switching the compose
  /// group mid-upload left an id pointing at the wrong server.
  List<int>? _pendingGifBytes;
  String? _pendingGifName;
  // The comment being replied to, or null for a top-level comment. A reply always goes to
  // the parent's own group, so replying pins the compose target to it.
  Comment? _replyTo;
  // A gif picked for the comment being composed, already uploaded to the target group's
  // server and held here until send (or removed via the thumbnail's X).
  bool _attachingGif = false;

  bool get _isCrossPost => (widget.copies?.length ?? 0) > 1;

  /// Switches which group a new comment posts to (null meaning all of them).
  ///
  /// A staged gif survives the switch now: it is held as bytes rather than as a media id
  /// belonging to one server, so retargeting it is just a matter of uploading it somewhere
  /// else at send time.
  void _setComposeGroup(String? groupId) {
    if (groupId == _composeGroupId) return;
    _composeGroupId = groupId;
  }

  /// Starts a reply to [c]: pins the compose group to the parent's (so it lands on the right
  /// server) and focuses the field. Tapping "Reply" on another comment just re-targets.
  void _startReply(Comment c) {
    setState(() {
      _replyTo = c;
      if (_isCrossPost && c.groupId != null) _setComposeGroup(c.groupId);
    });
    _commentFocus.requestFocus();
  }

  /// Cancels the reply AND releases the group it pinned.
  ///
  /// Starting a reply pins the target to the parent's group; cancelling used to leave that
  /// pin in place, so a member who backed out of a reply to write an ordinary comment
  /// silently kept sending to just that one group instead of returning to the "all groups"
  /// default they started from.
  void _cancelReply() => setState(() {
        _replyTo = null;
        _composeGroupId = null;
      });

  /// Reports [c] to its own group's host. Mirrors how a post is reported (post_card.dart):
  /// same reason sheet, same "reviewed within 24 hours" copy, same snack feedback.
  Future<void> _reportComment(Comment c) async {
    final gid = c.groupId ?? widget.groupId;
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kBgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const ReportSheet(subject: 'comment'),
    );
    if (reason == null || !mounted) return;
    try {
      await ref.read(contentApiProvider(gid)).reportComment(c.id, reason);
      if (mounted) _snack('Report sent. The host will review it.');
    } catch (_) {
      if (mounted) _snack('Could not send report. Try again.');
    }
  }

  /// Reports the check-in itself.
  ///
  /// This existed only on the feed card, so opening a thread took away the one way to
  /// report the thing you were reading. The comment menus below are no help for that: they
  /// report a comment, not the check-in it sits under.
  Future<void> _reportPost(Post post) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kBgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const ReportSheet(subject: 'check-in'),
    );
    if (reason == null || !mounted) return;
    try {
      await ref.read(contentApiProvider(widget.groupId)).reportPost(post.id, reason);
      if (mounted) _snack('Report sent. The host will review it.');
    } catch (_) {
      if (mounted) _snack('Could not send report. Try again.');
    }
  }

  /// The display name of the comment [c] is replying to, resolved from the loaded thread
  /// (same id, and same group for a merged cross-post thread). Null if it can't be found.
  /// The author of the comment [c] replies to, or null when it is not in this thread.
  ///
  /// Matched on (id, group) rather than id alone, because a comment id only identifies a row
  /// on its own server and two groups will happily both have a comment 15. The parent may
  /// also be a shared comment, in which case the merged thread shows ONE representative and
  /// the reply may point at any of its per-group copies - so every copy is a valid match.
  /// Without that, a reply written by someone who only sees one group would lose its
  /// "Replying to X" line for everyone reading the merged thread.
  String? _parentAuthorName(Comment c) {
    final pid = c.parentCommentId;
    if (pid == null) return null;
    for (final other in _comments) {
      if (other.id == pid && other.groupId == c.groupId) return other.authorName;
      for (final copy in other.copies) {
        if (copy.commentId == pid && copy.groupId == c.groupId) return other.authorName;
      }
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

  /// Saves the post's clip to the gallery. Gal.putVideo takes a file path, so the downloaded
  /// bytes are staged in a temp file first.
  Future<void> _saveVideo(int mediaId) async {
    try {
      final bytes = await ref.read(contentApiProvider(widget.groupId)).downloadMedia(mediaId);
      final file = File('${Directory.systemTemp.path}/checkin_clip_$mediaId.mp4');
      await file.writeAsBytes(bytes);
      await Gal.putVideo(file.path);
      if (mounted) _snack('Saved to your photos');
    } on GalException catch (_) {
      if (mounted) _snack('Allow photo access to save this');
    } catch (_) {
      if (mounted) _snack('Could not save the video');
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
    _highlightTimer?.cancel();
    _comment.dispose();
    _commentFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// After the thread loads from a notification, bring what the notification was about
  /// into view. Runs once.
  ///
  /// A named comment is scrolled to and flashed, so the member lands on the reply they were
  /// told about and can see which one it is. Without a named comment - a like, or a push
  /// from a server predating the comment id - the best available is the top of the thread,
  /// which on a long thread is why "it didn't take me to the comment" was the complaint.
  void _maybeFocusComments() {
    final target = widget.highlightCommentId;
    if ((!widget.focusComments && target == null) || _didFocusComments) return;
    _didFocusComments = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final named =
          target == null ? null : _comments.where((c) => _isTargetComment(c, target)).firstOrNull;
      if (named != null) {
        unawaited(_scrollToRow(_rowKeyFor(named)));
        return;
      }
      // No particular comment to go to: a like, a push from a server predating the comment
      // id, or a comment that has since been deleted. The top of the thread is the best
      // available answer.
      final ctx = _commentsKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
      }
    });
  }

  /// Brings one comment into view and flashes it.
  ///
  /// The stepping is not defensive padding. A ListView builds only the rows near the
  /// viewport, even though every child widget is handed to it up front, so a comment forty
  /// replies down has no context to scroll to until the list has been scrolled far enough
  /// to build it. Each pass moves most of a screen and waits for the frame that builds the
  /// next stretch; the final ensureVisible does the precise positioning. It stops the
  /// moment the row exists, so a comment already on screen costs nothing.
  Future<void> _scrollToRow(String rowKey) async {
    // Generous, and bounded: the loop exits as soon as the row is built, and the cap only
    // matters if something else is wrong - in which case stopping beats scrolling forever.
    for (var pass = 0; pass < 60; pass++) {
      // Checked at the top of every pass, not just the first: each pass ends on a frame
      // boundary, and the member can leave the thread while this is still walking it.
      if (!mounted || !_scroll.hasClients) return;
      final ctx = _commentKeys[rowKey]?.currentContext;
      // ctx.mounted as well as the State's: the row is reached through a GlobalKey, so it
      // can be torn down independently of this screen while the walk is between frames.
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            // A little below the top edge, so the replies under it are visible too rather
            // than the comment sitting flush against the app bar.
            alignment: 0.3);
        if (mounted) _flash(rowKey);
        return;
      }
      final pos = _scroll.position;
      if (pos.pixels >= pos.maxScrollExtent) return; // the end, and it is not here
      _scroll.jumpTo(min(pos.pixels + pos.viewportDimension * 0.8, pos.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// A row's identity in this thread: its group and its id there. See [_commentKeys] for
  /// why the group half is not optional.
  String _rowKeyFor(Comment c) => '${c.groupId ?? widget.groupId ?? ''}:${c.id}';

  /// Whether [c] is the comment a notification named. The notification came from
  /// [PostDetailScreen.groupId]'s server, so its id only means anything there.
  ///
  /// A collapsed cross-comment stands in for one copy per group and keeps just one of their
  /// ids as its own, so the copies are what say which id it holds on which server - without
  /// checking them, a notification from the group whose copy did not win would scroll to
  /// the top of the thread instead of to the comment.
  bool _isTargetComment(Comment c, int commentId) {
    if (c.id == commentId && (c.groupId ?? widget.groupId) == widget.groupId) return true;
    return c.copies.any((copy) => copy.commentId == commentId && copy.groupId == widget.groupId);
  }

  /// Briefly tints one comment, so a thread that scrolled to the right place says WHICH
  /// comment it scrolled to instead of leaving the member to guess.
  void _flash(String rowKey) {
    setState(() => _highlighted = rowKey);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _highlighted = null);
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
        // One comment sent to several groups arrives once per server; show it once.
        comments = collapseCrossComments([for (final l in lists) ...l]);
        post = post.withCopies(copies);
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
    final gifBytes = _pendingGifBytes;
    if ((text.isEmpty && gifBytes == null) || _sending) return;
    setState(() => _sending = true);
    FocusScope.of(context).unfocus();
    // A comment can go to every group holding a copy of the check-in, not just one. Each
    // group is its own server, so this is a fan-out of separate requests carrying one
    // client-generated id - the same shape cross-posting itself uses. That id is what lets
    // the copies be shown once here (collapseCrossComments) and pushed once to a member of
    // several of those groups (see the server's own collapseFor).
    //
    // A reply is pinned to its parent's group (see _startReply), so it never fans out: the
    // parent comment id it carries only means anything on that one server.
    final replyTo = _replyTo;
    // A reply carries a parentCommentId, and that id means something on exactly one server -
    // so a reply can never simply be broadcast the way a fresh comment is. It goes to the
    // groups that hold the comment being answered, each with THAT group's own parent id.
    //
    // For an ordinary single-group comment that is one group, which is what "limit a reply to
    // the group of the person you are replying to" means. For a comment that was itself sent
    // everywhere, it is every group that can see it - otherwise replying to something the
    // whole group read would answer only whichever server happened to answer first, and the
    // other groups would see the question and never the answer.
    final List<({int postId, String? groupId, int? parentId})> targets;
    if (replyTo != null) {
      targets = _replyTargets(replyTo);
    } else {
      targets = [
        for (final t in _sendTargets()) (postId: t.postId, groupId: t.groupId, parentId: null)
      ];
    }
    final crossCommentId = targets.length > 1 ? _newCrossCommentId() : null;
    final added = <Comment>[];
    var failedCount = 0;
    for (final target in targets) {
      try {
        final api = ref.read(contentApiProvider(target.groupId));
        // The gif is re-uploaded per server: media ids are per-server, so one group's id
        // means nothing (or worse, something else) on another.
        // Gated per target exactly as the shared id is. A server predating comment media
        // rejects the unknown mediaId field, and that rejection fails the WHOLE request -
        // so attaching a gif would cost that group the member's words as well, when it
        // would have taken the text on its own. It gets the comment without the picture.
        int? mediaId;
        if (gifBytes != null && (_account(target.groupId)?.commentMedia ?? false)) {
          mediaId = await api.uploadImageBytes(gifBytes, filename: _pendingGifName ?? 'reply.gif');
        }
        final c = await api.addComment(target.postId, text,
            parentCommentId: target.parentId,
            mediaId: mediaId,
            // Withheld from a server that would reject the unknown field. That copy simply
            // does not collapse with the others - see _supportsSharedId.
            crossCommentId: _supportsSharedId(target.groupId) ? crossCommentId : null);
        added.add(c.withGroup(_isCrossPost ? target.groupId : null));
      } catch (_) {
        failedCount++;
      }
    }
    if (!mounted) return;
    if (added.isEmpty) {
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not add comment')),
      );
      return;
    }
    _comment.clear();
    setState(() {
      // Append in place - no re-fetch, so the post and existing comments don't flash. The
      // copies collapse to one entry exactly as a re-fetch would render them.
      _comments = collapseCrossComments([..._comments, ...added]);
      _replyTo = null;
      _pendingGifBytes = null;
      _pendingGifName = null;
      _sending = false;
    });
    if (failedCount > 0) {
      // Partial success is worth saying out loud: the comment is up, but not everywhere the
      // member asked for, and silently pretending otherwise would leave them believing a
      // group had seen something it never received. Counted rather than hardcoded to "one" -
      // saying one group failed when two did is its own small lie.
      final groups = failedCount == 1 ? '1 group' : '$failedCount groups';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Posted, but $groups didn't get it")),
      );
    }
  }

  /// Opens the gif picker against [account]'s server, downloads the pick, and uploads it to
  /// that same server so the comment attaches re-hosted media - never a Klipy hotlink. Holds
  /// the resulting media id until send (or a tap on the thumbnail's X clears it).
  Future<void> _attachGif(ServerAccount account) async {
    final api = ref.read(contentApiProvider(account.id));
    final picked =
        await showGifPicker(context, search: (q, page) => api.gifSearch(query: q, page: page));
    if (picked == null || !mounted) return;
    setState(() => _attachingGif = true);
    try {
      final download = widget.gifDownloader ?? ApiClient.downloadExternalGif;
      final bytes = await download(picked.gifUrl);
      if (!mounted) return;
      setState(() {
        _attachingGif = false;
        // Held as bytes, not uploaded yet: the comment may be going to several servers, and
        // each needs its own copy re-hosted on it. Uploading happens per target in _send.
        _pendingGifBytes = bytes;
        _pendingGifName = '${picked.id}.gif';
      });
    } catch (_) {
      if (mounted) setState(() => _attachingGif = false);
      _snack("Couldn't add that gif. Try again.");
    }
  }

  void _removeGif() => setState(() {
        _pendingGifBytes = null;
        _pendingGifName = null;
      });

  /// Every copy a new comment should go to: all of them when no single group is picked,
  /// otherwise just that one.
  ///
  /// A group whose server predates crossComments is dropped from a fan-out rather than sent
  /// a field it would 400 on. It can still be commented in by picking it directly, which
  /// simply posts there with no shared id - exactly what happened before this existed.
  List<({int postId, String? groupId})> _sendTargets() {
    final copies = widget.copies;
    if (!_isCrossPost || copies == null) {
      return [(postId: widget.postId, groupId: widget.groupId)];
    }
    if (_composeGroupId != null) {
      for (final c in copies) {
        if (c.groupId == _composeGroupId) return [(postId: c.postId, groupId: c.groupId)];
      }
      final first = copies.first;
      return [(postId: first.postId, groupId: first.groupId)];
    }
    return [for (final c in copies) (postId: c.postId, groupId: c.groupId)];
  }

  /// Where a reply goes: every group holding the comment being answered, each paired with
  /// the parent id that group's own server issued.
  ///
  /// A comment sent to several groups keeps its per-group copies (see Comment.copies), so
  /// the reply can reach all of them. One that was only ever in one group resolves to that
  /// group alone. A copy whose group is no longer reachable is dropped rather than guessed
  /// at - sending another server's comment id would attach the reply to whatever unrelated
  /// row happens to hold that number.
  List<({int postId, String? groupId, int? parentId})> _replyTargets(Comment replyTo) {
    final copies = widget.copies;
    int? postIdIn(String groupId) {
      if (copies == null) return widget.postId;
      for (final c in copies) {
        if (c.groupId == groupId) return c.postId;
      }
      return null;
    }

    if (replyTo.copies.length > 1) {
      final out = <({int postId, String? groupId, int? parentId})>[];
      for (final copy in replyTo.copies) {
        final postId = postIdIn(copy.groupId);
        if (postId != null && _account(copy.groupId) != null) {
          out.add((postId: postId, groupId: copy.groupId, parentId: copy.commentId));
        }
      }
      if (out.isNotEmpty) return out;
    }
    final gid = replyTo.groupId;
    final postId = gid == null ? widget.postId : postIdIn(gid);
    return [
      (postId: postId ?? widget.postId, groupId: gid ?? widget.groupId, parentId: replyTo.id)
    ];
  }

  /// Whether this target's server understands the shared id.
  ///
  /// A group whose server predates it still RECEIVES the comment - it is simply sent without
  /// the id, exactly as a single-group comment always was. An earlier version dropped such a
  /// group from the fan-out entirely, which silently reduced "everyone" to "everyone with an
  /// up-to-date server" with no failure and no cue anywhere in the UI: the member had every
  /// reason to think they had spoken to all their groups.
  ///
  /// The cost of sending anyway is that the copy on the old server carries no id, so someone
  /// in that group AND another sees the comment twice until its host updates. A visible
  /// duplicate is a far smaller harm than words that never arrived, and it repairs itself.
  bool _supportsSharedId(String? groupId) => _account(groupId)?.crossComments ?? false;

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
                    // On the attachments, not on kind: a post carrying a clip is kind
                    // 'video', and gating on 'image' would render it as caption only.
                    if (post.media.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: AspectRatio(
                            aspectRatio: 4 / 3,
                            child: PostImageCarousel(
                              media: post.media,
                              groupId: widget.groupId,
                              onImageTap: (mediaId) => PhotoViewerScreen.open(
                                context,
                                media: post.media,
                                initialIndex: post.media
                                    .indexWhere((m) => m.id == mediaId)
                                    .clamp(0, post.media.length - 1),
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
              child: Row(children: [
                _allGroupsChip(),
                for (final c in copies) _groupChip(c.groupId),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  /// The default target on a cross-post: every group holding a copy.
  ///
  /// First in the row and selected to begin with, because the check-in itself went to all of
  /// them - a reply defaulting to one of them was the odd half of that pair, and is what
  /// made saying something to everyone a three-step chore.
  Widget _allGroupsChip() {
    final selected = _composeGroupId == null;
    final color = context.accent;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Comment in all groups',
        child: ExcludeSemantics(
          child: GestureDetector(
            onTap: () => setState(() => _setComposeGroup(null)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? Color.alphaBlend(color.withValues(alpha: 0.20), kBgMain)
                    : kBgSurface,
                border: Border.all(color: selected ? color : kBorder),
                borderRadius: BorderRadius.circular(9999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.workspaces_outlined, size: 12, color: selected ? color : kFgSecondary),
                  const SizedBox(width: 5),
                  Text('All groups',
                      style: TextStyle(
                          color: selected ? kFgPrimary : kFgSecondary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
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
        onTap: () => setState(() => _setComposeGroup(groupId)),
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
                groupId: widget.groupId,
                // Tappable, so it is announced as whose profile it opens rather than as the
                // single letter drawn on it.
                semanticLabel: post.authorName),
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
          // A photo saves as-is; a clip takes its own putVideo path (staged to a temp file).
          if (post.imageMedia.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.download_outlined, size: 22, color: kFgSecondary),
              tooltip: 'Save photo',
              onPressed: () => _savePhoto(post.imageMedia.first.id),
            ),
          if (post.videoMedia.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.download_outlined, size: 22, color: kFgSecondary),
              tooltip: 'Save video',
              onPressed: () => _saveVideo(post.videoMedia.first.id),
            ),
          _postMenu(post),
        ],
      ),
    );
  }

  Widget _commentRow(Comment c) {
    // A merged comment opens the commenter's profile on its own group's server.
    final gid = c.groupId ?? widget.groupId;
    final me = ref.read(contentAccountProvider(gid))?.user;
    final rowKey = _rowKeyFor(c);
    final key = _commentKeys.putIfAbsent(rowKey, GlobalKey.new);
    final lit = _highlighted == rowKey;
    final open = _openActions == rowKey;
    // A plain Container rather than an AnimatedContainer: with a null colour it is exactly
    // the Padding this row has always been, so an ordinary thread gains no widget and no
    // animation controller per comment. The tint arriving at once is also the point - it is
    // there to catch the eye on arrival, not to be a transition.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _openActions = open ? null : rowKey),
      child: Container(
        key: key,
        color: lit ? context.accent.withValues(alpha: 0.16) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
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
                    groupId: gid,
                    semanticLabel: c.authorName),
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
                    if (c.body.isNotEmpty)
                      Text(c.body,
                          style: const TextStyle(color: kFgSecondary, fontSize: 14, height: 1.35)),
                    if (c.mediaId case final mediaId?) ...[
                      if (c.body.isNotEmpty) const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: AuthImage(mediaId: mediaId, groupId: gid, fit: BoxFit.contain),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Reply and Report sit to the right of the comment rather than as small text
              // under it. The row's height is set by the name and body beside them, so a
              // full-size target costs nothing here - as text they were 17dp tall, and making
              // them tappable in place would have added about 20dp to every comment.
              // The slot is held whether the controls show or not: letting the row reflow on
              // tap rewraps the comment text under your finger, which reads as the thread
              // jumping rather than as something opening.
              SizedBox(
                width: 88,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Reply waits for a tap; the menu does not. Reporting is the one action
                    // that has to be findable without knowing a comment can be tapped at
                    // all, and there is nowhere else in a thread to report anything from.
                    if (open) _replyButton(c) else const SizedBox(width: 44),
                    // Your own comment has nothing to report, but its slot is held so the
                    // reply arrows line up down the thread.
                    if (me != null && me.id != c.authorId)
                      _commentMenu(c)
                    else
                      const SizedBox(width: 44),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One of the small text actions under a comment.
  ///
  /// The padding is the point. As bare text these were 17dp tall - a third of the 48dp both
  /// platforms ask for - and Reply and Report sat 14dp apart, which is a fiddly pair to hit
  /// accurately one-handed. The text itself is unchanged; only the area that answers a tap
  /// grew, and the row's old 4dp top gap is folded into it so the thread gains as little
  /// height as possible.
  /// The check-in's own menu. Report only for now, and only on someone else's - the same
  /// place a feed card keeps it, so the action is where a member already expects it.
  Widget _postMenu(Post post) {
    final me = ref.read(contentAccountProvider(widget.groupId))?.user;
    if (me == null || me.id == post.authorId) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      width: 44,
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz,
            size: 20, color: kFgSecondary, semanticLabel: 'More on this check-in'),
        tooltip: 'Check-in options',
        padding: EdgeInsets.zero,
        color: kBgSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: kBorder),
        ),
        onSelected: (v) {
          if (v == 'report') _reportPost(post);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'report',
            child: Row(
              children: [
                Icon(Icons.flag_outlined, size: 19, color: kFgPrimary),
                SizedBox(width: 10),
                Text('Report check-in', style: TextStyle(color: kFgPrimary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Reply to a comment: a full-size target in the empty space beside it.
  Widget _replyButton(Comment c) => SizedBox(
        height: 44,
        width: 44,
        child: IconButton(
          icon: Icon(Icons.reply_outlined,
              size: 19, color: kFgMuted, semanticLabel: 'Reply to ${c.authorName}'),
          tooltip: 'Reply to ${c.authorName}',
          padding: EdgeInsets.zero,
          onPressed: () => _startReply(c),
        ),
      );

  /// The same menu a check-in carries, for the actions that are not the common one. Report
  /// is the only entry today; it belongs behind a menu rather than beside Reply, where the
  /// two sat close enough to be mistaken for each other.
  Widget _commentMenu(Comment c) => SizedBox(
        height: 44,
        width: 44,
        child: PopupMenuButton<String>(
          icon: Icon(Icons.more_horiz,
              size: 19, color: kFgMuted, semanticLabel: 'More on ${c.authorName}\'s comment'),
          tooltip: 'Comment options',
          padding: EdgeInsets.zero,
          color: kBgSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: kBorder),
          ),
          onSelected: (v) {
            if (v == 'report') _reportComment(c);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'report',
              child: Row(
                children: [
                  Icon(Icons.flag_outlined, size: 19, color: kFgPrimary),
                  SizedBox(width: 10),
                  Text('Report comment', style: TextStyle(color: kFgPrimary)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _composer() {
    // The picker searches against one server (whichever target can), but the chosen gif is
    // uploaded to every target at send. Offered only when EVERY target accepts comment media:
    // sending a gif-only comment to a group that cannot take one would arrive as an empty
    // comment and be refused, so it is better not to offer it than to half-deliver it.
    // Derived from where this send will actually go. A reply fans out over the groups
    // holding its parent (_replyTargets), which is a different set from a fresh comment's -
    // computing eligibility from the wrong one offered the gif button for targets that
    // could not take it.
    final replyTo = _replyTo;
    final targetGroups = replyTo != null
        ? [for (final t in _replyTargets(replyTo)) t.groupId]
        : [for (final t in _sendTargets()) t.groupId];
    final accounts = [for (final g in targetGroups) ref.watch(contentAccountProvider(g))];
    final searchAccount = accounts.where((a) => a?.gifSearch ?? false).firstOrNull;
    // Offered when ANY target can take it, not only when all can. Requiring all would let a
    // single group whose host has not updated remove gifs from every other group as well -
    // the same "don't reduce everyone to the least-updated server" rule the shared id
    // follows. The gif is withheld per target at send (see _send), so the group that cannot
    // take one still receives the comment itself.
    final gifAllowed = searchAccount != null && accounts.any((a) => a?.commentMedia ?? false);
    final targetAccount = searchAccount;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Outside the bar's surface: an attached gif should read as the gif itself,
          // not as a panel the width of the screen.
          if (_pendingGifBytes != null)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 10),
              child: _pendingGifThumbnail(),
            ),
          Container(
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
                // Cross-post: a comment goes to every group by default, or to one the poster
                // picks. While replying the group is pinned to the parent's (a parent comment
                // id only means anything on its own server), so the picker is hidden.
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
                          hintText: _replyTo != null
                              ? 'Reply to ${_replyTo!.authorName}…'
                              : 'Add a comment…',
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
                          // Right-aligned inside the field, matching compose's own gif icon.
                          suffixIcon: !gifAllowed
                              ? null
                              : IconButton(
                                  onPressed:
                                      _attachingGif ? null : () => _attachGif(targetAccount!),
                                  padding: EdgeInsets.zero,
                                  tooltip: 'Add a gif',
                                  icon: _attachingGif
                                      ? SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2, color: context.accent))
                                      : Icon(Icons.gif_box_outlined,
                                          color: context.accent, size: 22),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _comment,
                      builder: (_, val, __) {
                        final canSend =
                            (val.text.trim().isNotEmpty || _pendingGifBytes != null) && !_sending;
                        return IconButton(
                          onPressed: canSend ? _send : null,
                          icon: _sending
                              ? SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: context.accent))
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
        ],
      ),
    );
  }

  /// A small removable preview of the gif attached to the comment being composed, shown
  /// above the input until sent (or removed).
  Widget _pendingGifThumbnail() {
    final bytes = _pendingGifBytes;
    if (bytes == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 84,
              height: 84,
              // Straight from the staged bytes: nothing has been uploaded anywhere yet, so
              // there is no media id on any server to fetch it back from. errorBuilder
              // because these bytes came off a third-party CDN and a truncated or malformed
              // download must degrade to a placeholder, not throw during paint.
              child: Image.memory(
                Uint8List.fromList(bytes),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(
                  color: kBgSurfaceHover,
                  child: Icon(Icons.gif_box_outlined, color: kFgMuted),
                ),
              ),
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: _removeGif,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(color: kBgSurfaceHover, shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 14, color: kFgPrimary),
              ),
            ),
          ),
        ],
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

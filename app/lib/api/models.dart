// Plain data models mirroring the server's JSON responses.

import 'package:intl/intl.dart';

class ServerInfo {
  ServerInfo({required this.name, required this.initialized, this.color = '', this.publicUrl});

  final String name;
  final bool initialized;

  /// The group's admin-set palette color id (empty when none is chosen). Members render
  /// it so the merged feed tells groups apart.
  final String color;

  /// The server's canonical public base URL, when it advertises one (multi-group
  /// installs). Used to match push payloads back to a connected group.
  final String? publicUrl;

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
        name: j['name'] as String? ?? 'Check-In',
        initialized: j['initialized'] as bool? ?? false,
        color: j['color'] as String? ?? '',
        publicUrl: j['publicUrl'] as String?,
      );
}

class User {
  User({
    required this.id,
    required this.name,
    required this.phone,
    required this.isAdmin,
    this.firstName = '',
    this.lastName = '',
    this.profileMediaId,
    this.birthdayMonth = 0,
    this.birthdayDay = 0,
  });

  final int id;
  final String name; // display name
  final String firstName;
  final String lastName;
  final String phone;
  final bool isAdmin;
  final int? profileMediaId;

  /// The member's birthday month and day (1-based; 0 = unknown). The year is never sent by
  /// the server, so a member's age can't be derived - see [birthdayLabel].
  final int birthdayMonth;
  final int birthdayDay;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as int,
        name: j['name'] as String,
        firstName: j['firstName'] as String? ?? '',
        lastName: j['lastName'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        isAdmin: j['isAdmin'] as bool? ?? false,
        profileMediaId: j['profileMediaId'] as int?,
        birthdayMonth: (j['birthdayMonth'] as num?)?.toInt() ?? 0,
        birthdayDay: (j['birthdayDay'] as num?)?.toInt() ?? 0,
      );

  /// The birthday as "March 14" (month and day only), or '' when unknown.
  String get birthdayLabel {
    if (birthdayMonth < 1 || birthdayDay < 1) return '';
    // 2000 is a leap year, so Feb 29 formats fine; only the month/day are used.
    return DateFormat.MMMMd().format(DateTime(2000, birthdayMonth, birthdayDay));
  }
}

class Post {
  Post({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.kind,
    required this.body,
    required this.createdAt,
    required this.likeCount,
    required this.commentCount,
    required this.likedByViewer,
    this.mediaId,
    this.mediaIds = const [],
    this.authorPhotoId,
    this.location,
    this.commentsPreview = const [],
    this.people = const [],
    this.groupId,
    this.crossPostId,
    this.copies = const [],
  });

  final int id;
  final int authorId;
  final String authorName;
  final String kind; // 'text' | 'image'
  final String body;
  final DateTime createdAt;
  final int likeCount;
  final int commentCount;
  final bool likedByViewer;
  final int? mediaId;
  final List<int> mediaIds;
  final int? authorPhotoId;
  final String? location; // coarse "City, Country", null for most posts
  final List<CommentPreview> commentsPreview;

  /// Members tagged as appearing in the post (id for filtering, name for display).
  final List<({int id, String name})> people;

  /// Which connected group (server) this post came from. Never sent by the server -
  /// the client stamps it when fetching, so likes/comments/images on this post can be
  /// routed back to the right server in the multi-group views.
  final String? groupId;

  /// Shared id tying this copy to the same post shared to other groups at once. Server-set
  /// (null for a single-group post). Used to collapse the copies into one card.
  final String? crossPostId;

  /// The copies of a collapsed cross-post, one per group the viewer can see it in
  /// (including this one). Empty for an ordinary post; populated client-side in the merged
  /// feed so likers/comments can fan out to each group's server.
  final List<PostCopy> copies;

  /// True once this post stands in for the same post shared to more than one shown group.
  bool get isCrossPost => copies.length > 1;

  /// Engagement across all copies (falls back to this copy's own counts when not collapsed).
  int get totalLikes => isCrossPost ? copies.fold(0, (s, c) => s + c.likeCount) : likeCount;
  int get totalComments =>
      isCrossPost ? copies.fold(0, (s, c) => s + c.commentCount) : commentCount;
  bool get likedByViewerAny => isCrossPost ? copies.any((c) => c.likedByViewer) : likedByViewer;

  /// Returns this post tagged with its origin group.
  Post withGroup(String groupId) => _copy(groupId: groupId);

  /// Returns this post standing in for the given set of cross-post copies.
  Post withCopies(List<PostCopy> copies) => _copy(copies: copies);

  Post _copy({String? groupId, List<PostCopy>? copies}) => Post(
        id: id,
        authorId: authorId,
        authorName: authorName,
        kind: kind,
        body: body,
        createdAt: createdAt,
        likeCount: likeCount,
        commentCount: commentCount,
        likedByViewer: likedByViewer,
        mediaId: mediaId,
        mediaIds: mediaIds,
        authorPhotoId: authorPhotoId,
        location: location,
        commentsPreview: commentsPreview,
        people: people,
        groupId: groupId ?? this.groupId,
        crossPostId: crossPostId,
        copies: copies ?? this.copies,
      );

  /// The post's images in order. Prefers the multi-photo set, falling back to the legacy
  /// single cover so older posts still render.
  List<int> get images =>
      mediaIds.isNotEmpty ? mediaIds : (mediaId != null ? [mediaId!] : const []);

  /// Ids of the tagged members, for the feed's "include posts they're in" filter.
  List<int> get peopleIds => [for (final p in people) p.id];

  /// A short "with Bob & Carol" summary of the tagged people, or '' when none.
  String get peopleLabel {
    final names = [for (final p in people) p.name];
    if (names.isEmpty) return '';
    if (names.length == 1) return 'with ${names[0]}';
    if (names.length == 2) return 'with ${names[0]} & ${names[1]}';
    return 'with ${names[0]}, ${names[1]} & ${names.length - 2} others';
  }

  factory Post.fromJson(Map<String, dynamic> j) => Post(
        id: j['id'] as int,
        authorId: j['authorId'] as int,
        authorName: j['authorName'] as String? ?? '',
        kind: j['kind'] as String,
        body: j['body'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        likeCount: j['likeCount'] as int? ?? 0,
        commentCount: j['commentCount'] as int? ?? 0,
        likedByViewer: j['likedByViewer'] as bool? ?? false,
        mediaId: j['mediaId'] as int?,
        mediaIds: ((j['mediaIds'] as List?) ?? const []).map((e) => e as int).toList(),
        authorPhotoId: j['authorPhotoId'] as int?,
        location: j['location'] as String?,
        commentsPreview: ((j['commentsPreview'] as List?) ?? [])
            .map((e) => CommentPreview.fromJson(e as Map<String, dynamic>))
            .toList(),
        people: ((j['people'] as List?) ?? const [])
            .map((e) => (
                  id: (e as Map<String, dynamic>)['id'] as int,
                  name: e['name'] as String,
                ))
            .toList(),
        crossPostId: j['crossPostId'] as String?,
      );
}

/// One copy of a cross-post: which group's server holds it, that copy's post id, and its
/// own engagement (each group counts only its own members). The merged card sums these.
typedef PostCopy = ({
  String groupId,
  int postId,
  int likeCount,
  int commentCount,
  bool likedByViewer,
});

/// A lightweight comment (author + body) shown inline as a preview on feed cards.
class CommentPreview {
  CommentPreview({required this.authorId, required this.authorName, required this.body});

  final int authorId;
  final String authorName;
  final String body;

  factory CommentPreview.fromJson(Map<String, dynamic> j) => CommentPreview(
        authorId: (j['authorId'] as num?)?.toInt() ?? 0,
        authorName: j['authorName'] as String? ?? '',
        body: j['body'] as String? ?? '',
      );
}

class Comment {
  Comment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
    this.authorPhotoId,
    this.groupId,
    this.parentCommentId,
  });

  final int id;
  final int authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;
  final int? authorPhotoId;

  /// Which group's server this comment came from. Client-stamped (like [Post.groupId]) when
  /// a cross-post's thread is merged, so each comment can show its group; null otherwise.
  final String? groupId;

  /// The comment this one replies to (same server), or null for a top-level comment. Used to
  /// show a "replying to X" line and to route a reply to the parent's group.
  final int? parentCommentId;

  Comment withGroup(String? groupId) => Comment(
        id: id,
        authorId: authorId,
        authorName: authorName,
        body: body,
        createdAt: createdAt,
        authorPhotoId: authorPhotoId,
        groupId: groupId,
        parentCommentId: parentCommentId,
      );

  factory Comment.fromJson(Map<String, dynamic> j) => Comment(
        id: j['id'] as int,
        authorId: (j['userId'] as num?)?.toInt() ?? 0,
        authorName: j['authorName'] as String? ?? '',
        body: j['body'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        authorPhotoId: j['authorPhotoId'] as int?,
        parentCommentId: (j['parentCommentId'] as num?)?.toInt(),
      );
}

/// One entry on the admin's invite list (allowlist). [used] is true once someone has
/// signed up with this number.
class Invite {
  Invite({required this.phone, required this.used, this.createdAt});

  final String phone;
  final bool used;
  final DateTime? createdAt;

  factory Invite.fromJson(Map<String, dynamic> j) => Invite(
        phone: j['phone'] as String? ?? '',
        used: j['used'] as bool? ?? false,
        createdAt: j['createdAt'] != null ? DateTime.tryParse(j['createdAt'] as String) : null,
      );
}

class Birthday {
  Birthday({required this.userId, required this.name, required this.month, required this.day});

  final int userId;
  final String name;
  final int month;
  final int day;

  factory Birthday.fromJson(Map<String, dynamic> j) => Birthday(
        userId: j['userId'] as int,
        name: j['name'] as String,
        month: j['month'] as int,
        day: j['day'] as int,
      );
}

/// A member's content report flagging objectionable content (visible to the admin).
class ContentReport {
  ContentReport({
    required this.id,
    required this.reporterId,
    required this.reporterName,
    required this.reason,
    required this.dismissed,
    required this.createdAt,
    this.postId,
    this.commentId,
    this.contentBody = '',
    this.authorName = '',
  });

  final int id;
  final int reporterId;
  final String reporterName;
  final int? postId;
  final int? commentId;
  final String reason;
  final bool dismissed;
  final String contentBody;
  final String authorName;
  final DateTime createdAt;

  factory ContentReport.fromJson(Map<String, dynamic> j) => ContentReport(
        id: j['id'] as int,
        reporterId: j['reporterId'] as int,
        reporterName: j['reporterName'] as String? ?? '',
        postId: j['postId'] as int?,
        commentId: j['commentId'] as int?,
        reason: j['reason'] as String? ?? '',
        dismissed: j['dismissed'] as bool? ?? false,
        contentBody: j['contentBody'] as String? ?? '',
        authorName: j['authorName'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

/// A member's push settings: the three instant toggles, plus an optional daily digest that
/// replaces per-check-in pushes with a single summary at a chosen local hour.
class NotifyPrefs {
  const NotifyPrefs({
    required this.posts,
    required this.replies,
    required this.likes,
    required this.digestEnabled,
    required this.digestHour,
    required this.digestOffset,
  });

  final bool posts;
  final bool replies;
  final bool likes;

  /// When on, new-check-in pushes are replaced by one summary at [digestHour] (the
  /// member's local hour, 0-23). Replies and likes stay instant either way.
  final bool digestEnabled;
  final int digestHour;

  /// The member's UTC offset in minutes, which the server uses to work out when their
  /// chosen hour has arrived. The app refreshes it on launch so a DST shift self-corrects.
  final int digestOffset;

  /// "8:00 PM" - the digest time, for display.
  String get digestLabel => DateFormat.jm().format(DateTime(2000, 1, 1, digestHour));

  NotifyPrefs copyWith(
          {bool? posts, bool? replies, bool? likes, bool? digestEnabled, int? digestHour}) =>
      NotifyPrefs(
        posts: posts ?? this.posts,
        replies: replies ?? this.replies,
        likes: likes ?? this.likes,
        digestEnabled: digestEnabled ?? this.digestEnabled,
        digestHour: digestHour ?? this.digestHour,
        digestOffset: digestOffset,
      );

  factory NotifyPrefs.fromJson(Map<String, dynamic> j) => NotifyPrefs(
        posts: j['posts'] as bool? ?? true,
        replies: j['replies'] as bool? ?? true,
        likes: j['likes'] as bool? ?? true,
        digestEnabled: j['digestEnabled'] as bool? ?? false,
        digestHour: (j['digestHour'] as num?)?.toInt() ?? 20,
        digestOffset: (j['digestOffset'] as num?)?.toInt() ?? 0,
      );
}

/// Result of a successful login or signup.
class AuthResult {
  AuthResult({required this.token, required this.user});

  final String token;
  final User user;

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        token: j['token'] as String,
        user: User.fromJson(j['user'] as Map<String, dynamic>),
      );
}

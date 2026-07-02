// Plain data models mirroring the server's JSON responses.

class ServerInfo {
  ServerInfo({required this.name, required this.initialized});

  final String name;
  final bool initialized;

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
        name: j['name'] as String? ?? 'Check-In',
        initialized: j['initialized'] as bool? ?? false,
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
  });

  final int id;
  final String name; // display name
  final String firstName;
  final String lastName;
  final String phone;
  final bool isAdmin;
  final int? profileMediaId;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as int,
        name: j['name'] as String,
        firstName: j['firstName'] as String? ?? '',
        lastName: j['lastName'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        isAdmin: j['isAdmin'] as bool? ?? false,
        profileMediaId: j['profileMediaId'] as int?,
      );
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
      );
}

/// A lightweight comment (author + body) shown inline as a preview on feed cards.
class CommentPreview {
  CommentPreview({required this.authorName, required this.body});

  final String authorName;
  final String body;

  factory CommentPreview.fromJson(Map<String, dynamic> j) => CommentPreview(
        authorName: j['authorName'] as String? ?? '',
        body: j['body'] as String? ?? '',
      );
}

class Comment {
  Comment({
    required this.id,
    required this.authorName,
    required this.body,
    required this.createdAt,
    this.authorPhotoId,
  });

  final int id;
  final String authorName;
  final String body;
  final DateTime createdAt;
  final int? authorPhotoId;

  factory Comment.fromJson(Map<String, dynamic> j) => Comment(
        id: j['id'] as int,
        authorName: j['authorName'] as String? ?? '',
        body: j['body'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        authorPhotoId: j['authorPhotoId'] as int?,
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

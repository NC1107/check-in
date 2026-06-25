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
    this.authorPhotoId,
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
  final int? authorPhotoId;

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
        authorPhotoId: j['authorPhotoId'] as int?,
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

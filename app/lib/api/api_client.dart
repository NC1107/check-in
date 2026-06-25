import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';

import 'models.dart';

/// ApiClient wraps all HTTP calls to a Check-In server. The base URL (server address)
/// and bearer token are injected after the user connects and logs in.
class ApiClient {
  ApiClient({required String baseUrl, String? token})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          headers: token == null ? null : {'Authorization': 'Bearer $token'},
        ));

  final Dio _dio;

  /// imageUrl builds the authenticated URL for a media id. The token is sent via header
  /// by [cachedImageHeaders]; callers pass that to CachedNetworkImage.
  String imageUrl(int mediaId) => '${_dio.options.baseUrl}/api/media/$mediaId';

  Map<String, String> get authHeaders {
    final h = _dio.options.headers['Authorization'];
    return h == null ? {} : {'Authorization': h as String};
  }

  // ---- onboarding / auth ----

  Future<ServerInfo> serverInfo() async {
    final r = await _dio.get('/api/server-info');
    return ServerInfo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<({bool allowed, bool isFirstAdmin})> checkPhone(String phone) async {
    final r = await _dio.post('/api/auth/check-phone', data: {'phone': phone});
    final j = r.data as Map<String, dynamic>;
    return (allowed: j['allowed'] as bool, isFirstAdmin: j['isFirstAdmin'] as bool? ?? false);
  }

  Future<AuthResult> signup({
    required String phone,
    required String firstName,
    required String lastName,
    String? displayName,
    required String birthday, // YYYY-MM-DD
    required String password,
    int? mediaId,
  }) async {
    final r = await _dio.post('/api/auth/signup', data: {
      'phone': phone,
      'firstName': firstName,
      'lastName': lastName,
      if (displayName != null && displayName.trim().isNotEmpty) 'displayName': displayName.trim(),
      'birthday': birthday,
      'password': password,
      if (mediaId != null) 'mediaId': mediaId,
    });
    return AuthResult.fromJson(r.data as Map<String, dynamic>);
  }

  Future<AuthResult> login({required String phone, required String password}) async {
    final r = await _dio.post('/api/auth/login', data: {'phone': phone, 'password': password});
    return AuthResult.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> logout() => _dio.post('/api/auth/logout');

  /// me returns the currently authenticated user (used to validate a restored token).
  Future<User> me() async {
    final r = await _dio.get('/api/me');
    return User.fromJson(r.data as Map<String, dynamic>);
  }

  /// setProfilePhoto attaches an already-uploaded media item as the current user's
  /// avatar and returns the updated user. Used during signup once a token exists.
  Future<User> setProfilePhoto(int mediaId) async {
    final r = await _dio.put('/api/me/photo', data: {'mediaId': mediaId});
    return User.fromJson(r.data as Map<String, dynamic>);
  }

  // ---- feed / content ----

  Future<List<Post>> feed({int? authorId, DateTime? before}) async {
    final r = await _dio.get('/api/feed', queryParameters: {
      if (authorId != null) 'author': authorId,
      if (before != null) 'before': before.toUtc().toIso8601String(),
    });
    return _posts(r.data);
  }

  Future<List<User>> searchUsers(String query) async {
    final r = await _dio.get('/api/users', queryParameters: {'search': query});
    return ((r.data as Map<String, dynamic>)['users'] as List? ?? [])
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Post>> userPosts(int userId, {DateTime? before}) async {
    final r = await _dio.get('/api/users/$userId/posts', queryParameters: {
      if (before != null) 'before': before.toUtc().toIso8601String(),
    });
    return _posts(r.data);
  }

  Future<Post> getPost(int id) async {
    final r = await _dio.get('/api/posts/$id');
    return Post.fromJson(r.data as Map<String, dynamic>);
  }

  Future<Post> createPost({required String kind, required String body, int? mediaId}) async {
    final r = await _dio.post('/api/posts', data: {
      'kind': kind,
      'body': body,
      if (mediaId != null) 'mediaId': mediaId,
    });
    return Post.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> deletePost(int id) => _dio.delete('/api/posts/$id');

  Future<void> like(int postId) => _dio.post('/api/posts/$postId/like');
  Future<void> unlike(int postId) => _dio.delete('/api/posts/$postId/like');

  Future<List<Comment>> comments(int postId) async {
    final r = await _dio.get('/api/posts/$postId/comments');
    return ((r.data as Map<String, dynamic>)['comments'] as List? ?? [])
        .map((e) => Comment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Comment> addComment(int postId, String body) async {
    final r = await _dio.post('/api/posts/$postId/comments', data: {'body': body});
    return Comment.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<Birthday>> upcomingBirthdays() async {
    final r = await _dio.get('/api/birthdays/upcoming');
    return ((r.data as Map<String, dynamic>)['birthdays'] as List? ?? [])
        .map((e) => Birthday.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// uploadImage sends a file and returns the new media id.
  Future<int> uploadImage(String filePath) async {
    final ext = filePath.split('.').last.toLowerCase();
    final contentType = switch (ext) {
      'png' => MediaType('image', 'png'),
      'gif' => MediaType('image', 'gif'),
      'webp' => MediaType('image', 'webp'),
      _ => MediaType('image', 'jpeg'),
    };
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, contentType: contentType),
    });
    final r = await _dio.post('/api/media', data: form);
    return (r.data as Map<String, dynamic>)['id'] as int;
  }

  // ---- admin ----

  Future<Map<String, dynamic>> uploadContacts(List<String> phones) async {
    final r = await _dio.post('/api/admin/contacts', data: {'phones': phones});
    return r.data as Map<String, dynamic>;
  }

  Future<List<User>> adminListUsers() async {
    final r = await _dio.get('/api/admin/users');
    return ((r.data as Map<String, dynamic>)['users'] as List? ?? [])
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> revokeUser(int id) => _dio.delete('/api/admin/users/$id');

  List<Post> _posts(dynamic data) =>
      ((data as Map<String, dynamic>)['posts'] as List? ?? [])
          .map((e) => Post.fromJson(e as Map<String, dynamic>))
          .toList();
}

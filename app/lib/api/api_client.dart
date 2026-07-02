import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';

import 'models.dart';

/// ApiClient wraps all HTTP calls to a Check-In server. The base URL (server address)
/// and bearer token are injected after the user connects and logs in.
class ApiClient {
  ApiClient({required String baseUrl, String? token, void Function()? onUnauthorized})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          // Generous send/receive windows: image uploads are re-encoded server-side
          // (EXIF/orientation), which can take a while on a loaded self-hosted box. A
          // tight timeout made the first attempt look like a failure while the server
          // actually succeeded, prompting a confusing retry.
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 60),
          headers: token == null ? null : {'Authorization': 'Bearer $token'},
        )) {
    if (onUnauthorized != null) {
      _dio.interceptors.add(InterceptorsWrapper(
        onError: (e, handler) {
          // We sent a token but the server rejected it → the session is invalid/expired.
          // Sign out so the user lands on login and can re-authenticate (vs. being stuck).
          if (e.response?.statusCode == 401 && token != null) onUnauthorized();
          handler.next(e);
        },
      ));
    }
  }

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

  /// checkPhone reports whether a number may sign up ([allowed]), already has an account
  /// ([registered] → route to login), and whether it would be the first/host account.
  Future<({bool allowed, bool registered, bool isFirstAdmin})> checkPhone(String phone) async {
    final r = await _dio.post('/api/auth/check-phone', data: {'phone': phone});
    final j = r.data as Map<String, dynamic>;
    return (
      allowed: j['allowed'] as bool? ?? false,
      registered: j['registered'] as bool? ?? false,
      isFirstAdmin: j['isFirstAdmin'] as bool? ?? false,
    );
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

  /// resetPassword redeems a host-issued recovery code to set a new password, returning a
  /// fresh session (the device is logged in on success).
  Future<AuthResult> resetPassword({
    required String phone,
    required String code,
    required String newPassword,
  }) async {
    final r = await _dio.post('/api/auth/reset-password',
        data: {'phone': phone, 'code': code, 'newPassword': newPassword});
    return AuthResult.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> logout() => _dio.post('/api/auth/logout');

  /// me returns the currently authenticated user (used to validate a restored token).
  Future<User> me() async {
    final r = await _dio.get('/api/me');
    return User.fromJson(r.data as Map<String, dynamic>);
  }

  // ---- push notifications ----

  /// registerDevice stores this device's FCM token server-side so it can receive push.
  /// Safe to call repeatedly (the server upserts on the token).
  Future<void> registerDevice({required String token, required String platform}) =>
      _dio.post('/api/me/devices', data: {'token': token, 'platform': platform});

  /// unregisterDevice removes a token (called on logout so a signed-out phone stops
  /// receiving this account's notifications).
  Future<void> unregisterDevice(String token) =>
      _dio.delete('/api/me/devices', data: {'token': token});

  /// notificationPrefs returns the per-account push opt-outs.
  Future<({bool posts, bool replies})> notificationPrefs() async {
    final r = await _dio.get('/api/me/notifications');
    final j = r.data as Map<String, dynamic>;
    return (posts: j['posts'] as bool? ?? true, replies: j['replies'] as bool? ?? true);
  }

  /// updateNotificationPrefs toggles the opt-outs. Omitted fields keep their value.
  Future<({bool posts, bool replies})> updateNotificationPrefs({bool? posts, bool? replies}) async {
    final r = await _dio.patch('/api/me/notifications', data: {
      if (posts != null) 'posts': posts,
      if (replies != null) 'replies': replies,
    });
    final j = r.data as Map<String, dynamic>;
    return (posts: j['posts'] as bool? ?? true, replies: j['replies'] as bool? ?? true);
  }

  /// setProfilePhoto attaches an already-uploaded media item as the current user's
  /// avatar and returns the updated user. Used during signup once a token exists.
  Future<User> setProfilePhoto(int mediaId) async {
    final r = await _dio.put('/api/me/photo', data: {'mediaId': mediaId});
    return User.fromJson(r.data as Map<String, dynamic>);
  }

  /// updateProfile changes the current user's display name and, optionally, their
  /// first/last name, returning the updated user. Omitted name parts are preserved.
  Future<User> updateProfile({required String name, String? firstName, String? lastName}) async {
    final r = await _dio.patch('/api/me', data: {
      'name': name,
      if (firstName != null) 'firstName': firstName,
      if (lastName != null) 'lastName': lastName,
    });
    return User.fromJson(r.data as Map<String, dynamic>);
  }

  /// getUser fetches a single user by id.
  Future<User> getUser(int id) async {
    final r = await _dio.get('/api/users/$id');
    return User.fromJson(r.data as Map<String, dynamic>);
  }

  /// search returns check-ins matching the query (caption or comment text) plus people
  /// whose name matches. The server returns empty for queries under 2 characters.
  Future<({List<Post> posts, List<User> people})> search(String query) async {
    final r = await _dio.get('/api/search', queryParameters: {'q': query});
    final j = r.data as Map<String, dynamic>;
    final posts =
        (j['posts'] as List? ?? []).map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
    final people =
        (j['people'] as List? ?? []).map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
    return (posts: posts, people: people);
  }

  // ---- feed / content ----

  Future<List<Post>> feed(
      {int? authorId, String? location, DateTime? before, int? beforeId}) async {
    final r = await _dio.get('/api/feed', queryParameters: {
      if (authorId != null) 'author': authorId,
      if (location != null && location.isNotEmpty) 'location': location,
      if (before != null) 'before': before.toUtc().toIso8601String(),
      if (before != null && beforeId != null) 'before_id': beforeId,
    });
    return _posts(r.data);
  }

  /// locations returns the distinct place labels across all check-ins (most-used first),
  /// to populate the feed's location filter.
  Future<List<({String location, int count})>> locations() async {
    final r = await _dio.get('/api/locations');
    return ((r.data as Map<String, dynamic>)['locations'] as List? ?? [])
        .map((e) => (
              location: (e as Map<String, dynamic>)['location'] as String,
              count: e['count'] as int,
            ))
        .toList();
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

  Future<Post> createPost(
      {required String kind,
      required String body,
      List<int>? mediaIds,
      String? location,
      List<int>? peopleIds}) async {
    final r = await _dio.post('/api/posts', data: {
      'kind': kind,
      'body': body,
      if (mediaIds != null && mediaIds.isNotEmpty) 'mediaIds': mediaIds,
      if (location != null && location.isNotEmpty) 'location': location,
      if (peopleIds != null && peopleIds.isNotEmpty) 'peopleIds': peopleIds,
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

  /// downloadMedia fetches the raw bytes of a media item (with the auth header) so the
  /// app can save it to the device gallery.
  Future<Uint8List> downloadMedia(int mediaId) async {
    final r = await _dio.get<List<int>>(
      '/api/media/$mediaId',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data ?? const []);
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

  /// uploadImageBytes sends already-encoded JPEG bytes (from a client-side downscale /
  /// transcode) and returns the new media id. Used so the server never has to decode a
  /// full-resolution photo or an iPhone HEIC it can't read.
  Future<int> uploadImageBytes(List<int> bytes, {String filename = 'upload.jpg'}) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes,
          filename: filename, contentType: MediaType('image', 'jpeg')),
    });
    final r = await _dio.post('/api/media', data: form);
    return (r.data as Map<String, dynamic>)['id'] as int;
  }

  // ---- admin ----

  Future<Map<String, dynamic>> uploadContacts(List<String> phones) async {
    final r = await _dio.post('/api/admin/contacts', data: {'phones': phones});
    return r.data as Map<String, dynamic>;
  }

  /// adminListAllowed returns the invite list (allowlist) — every number that may sign
  /// up, plus whether it has already joined.
  Future<List<Invite>> adminListAllowed() async {
    final r = await _dio.get('/api/admin/allowed');
    return ((r.data as Map<String, dynamic>)['invites'] as List? ?? [])
        .map((e) => Invite.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// adminRemoveInvite removes a pending number from the invite list. Existing accounts
  /// are unaffected (revoke those from the members list instead).
  Future<void> adminRemoveInvite(String phone) =>
      _dio.delete('/api/admin/allowed', data: {'phone': phone});

  Future<List<User>> adminListUsers() async {
    final r = await _dio.get('/api/admin/users');
    return ((r.data as Map<String, dynamic>)['users'] as List? ?? [])
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> revokeUser(int id) => _dio.delete('/api/admin/users/$id');

  // ---- reports ----

  Future<void> reportPost(int postId, String reason) =>
      _dio.post('/api/posts/$postId/report', data: {'reason': reason});

  Future<List<ContentReport>> adminListReports() async {
    final r = await _dio.get('/api/admin/reports');
    return ((r.data as Map<String, dynamic>)['reports'] as List? ?? [])
        .map((e) => ContentReport.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> adminDismissReport(int reportId) => _dio.delete('/api/admin/reports/$reportId');

  // ---- blocks ----

  Future<bool> isBlocked(int userId) async {
    final r = await _dio.get('/api/me/blocks/$userId');
    return (r.data as Map<String, dynamic>)['blocked'] as bool? ?? false;
  }

  Future<void> blockUser(int userId) => _dio.post('/api/me/blocks/$userId');

  Future<void> unblockUser(int userId) => _dio.delete('/api/me/blocks/$userId');

  // ---- account deletion ----

  Future<void> deleteAccount() => _dio.delete('/api/me');

  /// issueResetCode (admin) generates a single-use recovery code for a member to relay to
  /// them out-of-band; they redeem it with [resetPassword].
  Future<({String code, String name, DateTime expiresAt})> issueResetCode(int userId) async {
    final r = await _dio.post('/api/admin/users/$userId/reset-code');
    final j = r.data as Map<String, dynamic>;
    return (
      code: j['code'] as String,
      name: j['name'] as String,
      expiresAt: DateTime.parse(j['expiresAt'] as String),
    );
  }

  List<Post> _posts(dynamic data) => ((data as Map<String, dynamic>)['posts'] as List? ?? [])
      .map((e) => Post.fromJson(e as Map<String, dynamic>))
      .toList();
}

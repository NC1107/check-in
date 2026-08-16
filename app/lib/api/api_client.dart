import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';

import 'models.dart';

/// The build's version, sent on every request as X-Client-Version. Nothing consumes it
/// yet; it exists so a server can eventually tell an old app from a new one (and gate a
/// feature on it) without waiting a release cycle for the header to reach the field.
///
/// Hardcoded because the app carries no package_info_plus dependency - release tooling
/// bumps it with pubspec's version, and a test fails the build when the two drift.
const kClientVersion = '0.1.0';

/// The content type to upload a file under, from its extension. The server sniffs the
/// bytes anyway, so this only has to be honest enough not to be rejected out of hand -
/// but it is the one place the app names its own upload types, and both upload paths read
/// it so a raw and a re-encoded upload can never disagree.
MediaType uploadContentType(String path) => switch (fileExtension(path)) {
      'png' => MediaType('image', 'png'),
      'gif' => MediaType('image', 'gif'),
      'webp' => MediaType('image', 'webp'),
      'mp4' => MediaType('video', 'mp4'),
      _ => MediaType('image', 'jpeg'),
    };

/// A path's extension, lowercased and without the dot ('' when it has none).
String fileExtension(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
}

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
          headers: {
            'X-Client-Version': kClientVersion,
            if (token != null) 'Authorization': 'Bearer $token',
          },
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
  /// by [authHeaders]; callers pass that to CachedNetworkImage.
  ///
  /// [variant] asks for a derived file instead of the stored one - 'poster' for a clip's
  /// still frame. The server falls back to the main file for a variant it has nothing
  /// for, so callers must only ask when they know one exists (see [PostMedia.hasPoster]).
  String imageUrl(int mediaId, {String? variant}) {
    final url = '${_dio.options.baseUrl}/api/media/$mediaId';
    return variant == null ? url : '$url?variant=$variant';
  }

  /// The headers an image loader must send to fetch media itself. Those requests go out
  /// through CachedNetworkImage rather than dio, so they only carry what is put here.
  Map<String, String> get authHeaders {
    final h = _dio.options.headers['Authorization'];
    return {
      'X-Client-Version': kClientVersion,
      if (h != null) 'Authorization': h as String,
    };
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

  /// notificationPrefs returns the per-account push settings.
  Future<NotifyPrefs> notificationPrefs() async {
    final r = await _dio.get('/api/me/notifications');
    return NotifyPrefs.fromJson(r.data as Map<String, dynamic>);
  }

  /// updateNotificationPrefs changes the push settings. Omitted fields keep their value,
  /// so the app can send just [digestOffset] on launch to keep a DST shift from silently
  /// moving someone's digest.
  Future<NotifyPrefs> updateNotificationPrefs({
    bool? posts,
    bool? replies,
    bool? likes,
    bool? digestEnabled,
    int? digestHour,
    int? digestOffset,
  }) async {
    final r = await _dio.patch('/api/me/notifications', data: {
      if (posts != null) 'posts': posts,
      if (replies != null) 'replies': replies,
      if (likes != null) 'likes': likes,
      if (digestEnabled != null) 'digestEnabled': digestEnabled,
      if (digestHour != null) 'digestHour': digestHour,
      if (digestOffset != null) 'digestOffset': digestOffset,
    });
    return NotifyPrefs.fromJson(r.data as Map<String, dynamic>);
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
      {int? authorId, Set<String> locations = const {}, DateTime? before, int? beforeId}) async {
    final r = await _dio.get('/api/feed', queryParameters: {
      if (authorId != null) 'author': authorId,
      if (locations.isNotEmpty) 'location': locations.toList(),
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
      List<int>? peopleIds,
      String? crossPostId}) async {
    final r = await _dio.post('/api/posts', data: {
      'kind': kind,
      'body': body,
      if (mediaIds != null && mediaIds.isNotEmpty) 'mediaIds': mediaIds,
      if (location != null && location.isNotEmpty) 'location': location,
      if (peopleIds != null && peopleIds.isNotEmpty) 'peopleIds': peopleIds,
      if (crossPostId != null) 'crossPostId': crossPostId,
    });
    return Post.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> deletePost(int id) => _dio.delete('/api/posts/$id');

  Future<void> like(int postId) => _dio.post('/api/posts/$postId/like');
  Future<void> unlike(int postId) => _dio.delete('/api/posts/$postId/like');

  /// postLikers returns who liked a post, most recent first. The server allows this only
  /// for the post's own author (403 otherwise).
  Future<List<User>> postLikers(int postId) async {
    final r = await _dio.get('/api/posts/$postId/likes');
    return ((r.data as Map<String, dynamic>)['likers'] as List? ?? [])
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Comment>> comments(int postId) async {
    final r = await _dio.get('/api/posts/$postId/comments');
    return ((r.data as Map<String, dynamic>)['comments'] as List? ?? [])
        .map((e) => Comment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// addComment posts a comment. [mediaId] must only be sent to a server whose server-info
  /// advertises `commentMedia` - an older server 400s on the unknown field
  /// (DisallowUnknownFields); callers gate on that before ever passing one.
  Future<Comment> addComment(int postId, String body, {int? parentCommentId, int? mediaId}) async {
    final r = await _dio.post('/api/posts/$postId/comments', data: {
      'body': body,
      if (parentCommentId != null) 'parentCommentId': parentCommentId,
      if (mediaId != null) 'mediaId': mediaId,
    });
    return Comment.fromJson(r.data as Map<String, dynamic>);
  }

  /// gifSearch proxies a Klipy gif search (or, for an empty [query], trending) through this
  /// group's server, which holds the Klipy key so the client never sees it. Only meaningful
  /// against a server whose server-info advertises `gifSearch`.
  Future<GifSearchPage> gifSearch({String query = '', int page = 1}) async {
    final r = await _dio.get('/api/gifs/search', queryParameters: {
      if (query.isNotEmpty) 'q': query,
      'page': page,
    });
    return GifSearchPage.fromJson(r.data as Map<String, dynamic>);
  }

  /// downloadExternalGif fetches a chosen gif's bytes straight from Klipy's CDN (the
  /// [GifResult.gifUrl], never proxied - it carries no key) so the caller can re-upload them
  /// to this group's own server. A bare Dio, not this client's authenticated one: Klipy's
  /// CDN needs no bearer token and must never be sent this account's.
  static Future<List<int>> downloadExternalGif(String url) async {
    final r = await Dio().get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
    return r.data ?? const [];
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

  /// uploadImage sends a file as-is and returns the new media id.
  Future<int> uploadImage(String filePath) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, contentType: uploadContentType(filePath)),
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
          filename: filename, contentType: uploadContentType(filename)),
    });
    final r = await _dio.post('/api/media', data: form);
    return (r.data as Map<String, dynamic>)['id'] as int;
  }

  /// setMediaPoster attaches a still frame to a clip the caller uploaded, so the feed has
  /// something to show for it before there is a player. The frame goes through the server's
  /// image pipeline. Only the media's owner may set it.
  Future<void> setMediaPoster(int mediaId, List<int> bytes,
      {String filename = 'poster.jpg'}) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes,
          filename: filename, contentType: uploadContentType(filename)),
    });
    await _dio.post('/api/media/$mediaId/poster', data: form);
  }

  // ---- admin ----

  Future<Map<String, dynamic>> uploadContacts(List<String> phones) async {
    final r = await _dio.post('/api/admin/contacts', data: {'phones': phones});
    return r.data as Map<String, dynamic>;
  }

  /// adminListAllowed returns the invite list (allowlist) - every number that may sign
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

  /// renameServer changes this group's display name for everyone (admin only).
  Future<void> renameServer(String name) => _dio.patch('/api/admin/server', data: {'name': name});

  /// setGroupColor changes this group's palette color for everyone (admin only). An empty
  /// id clears it back to the automatic color.
  Future<void> setGroupColor(String colorId) =>
      _dio.patch('/api/admin/server', data: {'color': colorId});

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

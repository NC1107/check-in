import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/models.dart';

/// Persisted session: the server base URL, the auth token, and the current user.
class Session {
  const Session({this.baseUrl, this.token, this.user, this.serverInitialized = true});

  final String? baseUrl;
  final String? token;
  final User? user;

  /// Whether the connected server already has an admin. When false, the first signup
  /// becomes the host/admin, so onboarding shows host-setup framing instead of the
  /// invite-list verify copy. Defaults to true (the common case) until known.
  final bool serverInitialized;

  bool get hasServer => baseUrl != null && baseUrl!.isNotEmpty;
  bool get isLoggedIn => hasServer && token != null && user != null;

  Session copyWith({
    String? baseUrl,
    String? token,
    User? user,
    bool? serverInitialized,
    bool clearAuth = false,
  }) {
    return Session(
      baseUrl: baseUrl ?? this.baseUrl,
      token: clearAuth ? null : (token ?? this.token),
      user: clearAuth ? null : (user ?? this.user),
      serverInitialized: serverInitialized ?? this.serverInitialized,
    );
  }
}

const _kBaseUrl = 'base_url';
const _kToken = 'token';

/// SessionController loads and persists the session across launches. The token lives in
/// secure storage; the (non-secret) base URL lives in shared preferences.
class SessionController extends StateNotifier<Session> {
  SessionController() : super(const Session()) {
    _load();
  }

  final _secure = const FlutterSecureStorage();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_kBaseUrl);
    final token = await _secure.read(key: _kToken);
    User? user;
    // The user object is re-fetched lazily; we only restore enough to route.
    state = Session(baseUrl: baseUrl, token: token, user: user);
    if (baseUrl != null && token != null) {
      // Validate the token by fetching the current user.
      try {
        final client = ApiClient(baseUrl: baseUrl, token: token);
        user = await client.me();
        state = state.copyWith(user: user);
      } on DioException catch (_) {
        // Network error or 401 — token is invalid or server unreachable; sign out.
        await signOut();
      }
    }
  }

  Future<void> setServer(String baseUrl, {bool serverInitialized = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, baseUrl);
    state = state.copyWith(baseUrl: baseUrl, serverInitialized: serverInitialized);
  }

  Future<void> signIn(String token, User user) async {
    await _secure.write(key: _kToken, value: token);
    state = state.copyWith(token: token, user: user);
  }

  Future<void> signOut() async {
    await _secure.delete(key: _kToken);
    state = state.copyWith(clearAuth: true);
  }
}

final sessionProvider = StateNotifierProvider<SessionController, Session>(
  (ref) => SessionController(),
);

/// An ApiClient bound to the current server URL and token. Rebuilds whenever the
/// session changes.
final apiProvider = Provider<ApiClient>((ref) {
  final s = ref.watch(sessionProvider);
  return ApiClient(baseUrl: s.baseUrl ?? '', token: s.token);
});

/// The home feed as a refreshable provider. Invalidate it (e.g. after creating a post)
/// and the feed list updates without a manual pull-to-refresh.
final feedProvider = FutureProvider.autoDispose<List<Post>>((ref) {
  return ref.watch(apiProvider).feed();
});

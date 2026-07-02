import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/accent.dart';

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
      } on DioException catch (e) {
        // Only a real auth rejection means the stored token is bad. A network/timeout/
        // server-unreachable error must NOT drop a valid session — that's common for a
        // self-hosted box that's briefly offline. Keep the restored baseUrl/token; the
        // user can retry, and any later genuine 401 still triggers onUnauthorized.
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) {
          await signOut();
        }
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

  /// updateUser refreshes the cached current user (e.g. after editing the profile) so the
  /// rest of the app reflects the new name/photo.
  void updateUser(User user) {
    state = state.copyWith(user: user);
  }

  Future<void> signOut() async {
    await _secure.delete(key: _kToken);
    // Drop cached media so a different account/server — or a server whose data was reset
    // (which reuses media ids) — never shows another context's stale images.
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {
      // Cache clearing is best-effort; never block sign-out on it.
    }
    state = state.copyWith(clearAuth: true);
  }
}

final sessionProvider = StateNotifierProvider<SessionController, Session>(
  (ref) => SessionController(),
);

const _kAccentId = 'accent_id';

/// The user's chosen accent palette, persisted per-device. Drives the whole app
/// theme via [AccentPalette] on [ThemeData].
class AccentController extends StateNotifier<AccentPalette> {
  AccentController() : super(kAccentPresets.first) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = accentById(prefs.getString(_kAccentId));
  }

  Future<void> select(AccentPalette palette) async {
    state = palette;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccentId, palette.id);
  }
}

final accentProvider = StateNotifierProvider<AccentController, AccentPalette>(
  (ref) => AccentController(),
);

/// An ApiClient bound to the current server URL and token. Rebuilds whenever the
/// session changes.
final apiProvider = Provider<ApiClient>((ref) {
  final s = ref.watch(sessionProvider);
  return ApiClient(
    baseUrl: s.baseUrl ?? '',
    token: s.token,
    // If an authenticated request 401s, the session is dead — sign out so the user can
    // re-login instead of being stuck on errors.
    onUnauthorized: () => ref.read(sessionProvider.notifier).signOut(),
  );
});

/// The location filter applied to the home feed — null means all places. Set it and the
/// feed refetches server-side (so you see every check-in from that place, not just the
/// loaded page).
final feedLocationProvider = StateProvider<String?>((ref) => null);

/// The home feed as a refreshable provider. Invalidate it (e.g. after creating a post)
/// and the feed list updates without a manual pull-to-refresh.
final feedProvider = FutureProvider.autoDispose<List<Post>>((ref) {
  final location = ref.watch(feedLocationProvider);
  return ref.watch(apiProvider).feed(location: location);
});

/// Distinct place labels across all check-ins (most-used first), for the location filter.
final locationsProvider = FutureProvider.autoDispose<List<({String location, int count})>>((ref) {
  return ref.watch(apiProvider).locations();
});

const _kTermsAccepted = 'terms_accepted';

/// Tracks whether the user has accepted the in-app terms of service. Checked before
/// the auth screen so the EULA is presented on first launch (Apple Guideline 1.2).
class TermsController extends StateNotifier<bool> {
  TermsController() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_kTermsAccepted) ?? false;
  }

  Future<void> accept() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTermsAccepted, true);
    state = true;
  }
}

final termsProvider = StateNotifierProvider<TermsController, bool>(
  (ref) => TermsController(),
);

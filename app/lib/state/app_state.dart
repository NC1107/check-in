import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/accent.dart';

/// One connected group: a Check-In server plus this device's account on it. Because
/// every group is a physically separate server, identity (user id, photo, token) is
/// always per-group.
class ServerAccount {
  const ServerAccount({
    required this.id,
    required this.baseUrl,
    required this.serverName,
    this.nickname,
    this.token,
    this.user,
  });

  /// Stable id derived from the server's host (one subdomain per group). Used to key
  /// stored tokens, API clients, and image cache entries.
  final String id;
  final String baseUrl;
  final String serverName;

  /// Optional per-device rename. Purely local, so every member can label their groups
  /// however they like without touching the server (whose own name keeps refreshing
  /// into [serverName] underneath).
  final String? nickname;
  final String? token;

  /// The signed-in user on this server. Fetched lazily after restore, so it can be
  /// null for a moment (or while the server is unreachable) even when signed in.
  final User? user;

  bool get isSignedIn => token != null;

  /// What the UI calls this group: the local nickname when set, else the server's name.
  String get displayName {
    final n = nickname;
    return (n == null || n.isEmpty) ? serverName : n;
  }

  ServerAccount copyWith({
    String? serverName,
    String? nickname,
    bool clearNickname = false,
    String? token,
    User? user,
    bool clearAuth = false,
  }) {
    return ServerAccount(
      id: id,
      baseUrl: baseUrl,
      serverName: serverName ?? this.serverName,
      nickname: clearNickname ? null : (nickname ?? this.nickname),
      token: clearAuth ? null : (token ?? this.token),
      user: clearAuth ? null : (user ?? this.user),
    );
  }
}

/// The app-level session: every connected group plus which one is being viewed.
/// [activeGroupId] == null means the combined "All groups" view.
class MultiSession {
  const MultiSession({this.groups = const [], this.activeGroupId, this.restored = false});

  final List<ServerAccount> groups;
  final String? activeGroupId;

  /// True once persisted state has been loaded (so startup can tell "no groups yet"
  /// from "still restoring").
  final bool restored;

  List<ServerAccount> get signedIn => [
        for (final g in groups)
          if (g.isSignedIn) g
      ];

  bool get anySignedIn => groups.any((g) => g.isSignedIn);

  ServerAccount? byId(String? id) {
    if (id == null) return null;
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// The explicitly selected group, or null in the All view.
  ServerAccount? get active => byId(activeGroupId);

  /// The account backing screens that need "the current group" (profile, admin,
  /// settings, search): the active group, or the first signed-in one while viewing All.
  ServerAccount? get current {
    final a = active;
    if (a != null) return a;
    if (signedIn.isNotEmpty) return signedIn.first;
    return groups.isNotEmpty ? groups.first : null;
  }

  /// Whether the feed is showing the merged all-groups view (only meaningful with more
  /// than one signed-in group).
  bool get isAllView => activeGroupId == null && signedIn.length > 1;
}

const _kGroups = 'groups_json';
const _kActiveGroup = 'active_group_id'; // '' persists the All view
// Pre-multi-group keys, migrated into the group list on first launch of this build.
const _kLegacyBaseUrl = 'base_url';
const _kLegacyToken = 'token';

/// MultiSessionController loads and persists every group session across launches.
/// Tokens live in secure storage (keyed per group); the non-secret group list lives in
/// shared preferences.
class MultiSessionController extends StateNotifier<MultiSession> {
  MultiSessionController() : super(const MultiSession()) {
    _load();
  }

  /// Starts from a fixed state and skips restore/hydration — for widget tests.
  @visibleForTesting
  MultiSessionController.seeded(super.initial);

  final _secure = const FlutterSecureStorage();

  /// Derives the stable group id from a base URL: its host. One group per subdomain,
  /// so the host is unique, readable, and survives reinstalling the group.
  static String groupIdFor(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    return host.isNotEmpty ? host : baseUrl;
  }

  static String _tokenKey(String groupId) => 'token_$groupId';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    var entries = _decodeGroups(prefs.getString(_kGroups));

    // Migration: fold the old single {base_url, token} session into the list as the
    // first group, then drop the legacy keys.
    if (entries.isEmpty) {
      final legacyUrl = prefs.getString(_kLegacyBaseUrl);
      if (legacyUrl != null && legacyUrl.isNotEmpty) {
        final id = groupIdFor(legacyUrl);
        final legacyToken = await _secure.read(key: _kLegacyToken);
        if (legacyToken != null) {
          await _secure.write(key: _tokenKey(id), value: legacyToken);
        }
        entries = [(id: id, baseUrl: legacyUrl, name: 'Check-In', nickname: null)];
        await prefs.setString(_kGroups, _encodeGroups(entries));
        await prefs.setString(_kActiveGroup, id);
        await prefs.remove(_kLegacyBaseUrl);
        await _secure.delete(key: _kLegacyToken);
      }
    }

    final accounts = <ServerAccount>[];
    for (final e in entries) {
      final token = await _secure.read(key: _tokenKey(e.id));
      accounts.add(ServerAccount(
          id: e.id, baseUrl: e.baseUrl, serverName: e.name, nickname: e.nickname, token: token));
    }
    var activeId = prefs.getString(_kActiveGroup);
    if (activeId == '') activeId = null; // All view
    if (activeId != null && !accounts.any((g) => g.id == activeId)) {
      activeId = accounts.isNotEmpty ? accounts.first.id : null;
    }
    state = MultiSession(groups: accounts, activeGroupId: activeId, restored: true);

    // Hydrate each signed-in group's user (and refresh its display name) in parallel.
    for (final g in accounts) {
      if (g.isSignedIn) _hydrate(g);
    }
  }

  /// Validates a restored token by fetching the current user, and refreshes the group's
  /// display name. Only a real auth rejection drops the token — a network/timeout error
  /// must NOT sign the group out (a self-hosted box being briefly offline is normal).
  Future<void> _hydrate(ServerAccount g) async {
    final client = ApiClient(baseUrl: g.baseUrl, token: g.token);
    try {
      final user = await client.me();
      _update(g.id, (a) => a.copyWith(user: user));
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) await signOutGroup(g.id);
      return;
    } catch (_) {
      return;
    }
    try {
      final info = await client.serverInfo();
      if (info.name.isNotEmpty && info.name != g.serverName) {
        _update(g.id, (a) => a.copyWith(serverName: info.name));
        await _persistGroups();
      }
    } catch (_) {
      // Name refresh is cosmetic; ignore failures.
    }
  }

  void _update(String id, ServerAccount Function(ServerAccount) fn) {
    state = MultiSession(
      groups: [
        for (final g in state.groups)
          if (g.id == id) fn(g) else g
      ],
      activeGroupId: state.activeGroupId,
      restored: state.restored,
    );
  }

  Future<void> _persistGroups() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kGroups,
      _encodeGroups([
        for (final g in state.groups)
          (id: g.id, baseUrl: g.baseUrl, name: g.serverName, nickname: g.nickname)
      ]),
    );
  }

  Future<void> _persistActive() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveGroup, state.activeGroupId ?? '');
  }

  /// Connects (or re-connects) a group after a successful login/signup and makes it
  /// active. Re-adding an existing group replaces its entry (the re-login path).
  Future<void> addGroup({
    required String baseUrl,
    required String serverName,
    required String token,
    required User user,
  }) async {
    final id = groupIdFor(baseUrl);
    await _secure.write(key: _tokenKey(id), value: token);
    final account =
        ServerAccount(id: id, baseUrl: baseUrl, serverName: serverName, token: token, user: user);
    final others = [
      for (final g in state.groups)
        if (g.id != id) g
    ];
    state = MultiSession(groups: [...others, account], activeGroupId: id, restored: state.restored);
    await _persistGroups();
    await _persistActive();
  }

  /// Drops one group's token (e.g. its server rejected it) but keeps the entry, so the
  /// switcher can offer re-login. Never touches the other groups or the image cache.
  Future<void> signOutGroup(String id) async {
    await _secure.delete(key: _tokenKey(id));
    _update(id, (g) => g.copyWith(clearAuth: true));
  }

  /// Leaves a group entirely: token gone, entry gone.
  Future<void> removeGroup(String id) async {
    await _secure.delete(key: _tokenKey(id));
    final groups = [
      for (final g in state.groups)
        if (g.id != id) g
    ];
    var active = state.activeGroupId;
    if (active == id) active = groups.isNotEmpty ? groups.first.id : null;
    state = MultiSession(groups: groups, activeGroupId: active, restored: state.restored);
    await _persistGroups();
    await _persistActive();
  }

  /// Sets (or clears, with null/empty) this device's local name for a group. Purely
  /// cosmetic and per-device: the server's own name is untouched and reappears wherever
  /// no nickname is set.
  Future<void> renameGroup(String id, String? nickname) async {
    final trimmed = nickname?.trim() ?? '';
    _update(id,
        (g) => trimmed.isEmpty ? g.copyWith(clearNickname: true) : g.copyWith(nickname: trimmed));
    await _persistGroups();
  }

  /// Switches the viewed group; null selects the combined All view.
  Future<void> setActive(String? id) async {
    state = MultiSession(groups: state.groups, activeGroupId: id, restored: state.restored);
    await _persistActive();
  }

  /// Refreshes the cached user for a group (e.g. after editing the profile there).
  void updateUser(String groupId, User user) {
    _update(groupId, (g) => g.copyWith(user: user));
  }

  static List<({String id, String baseUrl, String name, String? nickname})> _decodeGroups(
      String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list.cast<Map<String, dynamic>>())
          (
            id: e['id'] as String,
            baseUrl: e['baseUrl'] as String,
            name: e['name'] as String? ?? 'Check-In',
            nickname: e['nickname'] as String?,
          )
      ];
    } catch (_) {
      return const [];
    }
  }

  static String _encodeGroups(
      List<({String id, String baseUrl, String name, String? nickname})> entries) {
    return jsonEncode([
      for (final e in entries)
        {
          'id': e.id,
          'baseUrl': e.baseUrl,
          'name': e.name,
          if (e.nickname != null) 'nickname': e.nickname,
        }
    ]);
  }
}

final multiSessionProvider = StateNotifierProvider<MultiSessionController, MultiSession>(
  (ref) => MultiSessionController(),
);

/// An ApiClient bound to one group. A 401 there signs out ONLY that group — the other
/// groups' sessions (and the shared image cache) stay intact.
final apiForGroupProvider = Provider.family<ApiClient, String>((ref, groupId) {
  final g = ref.watch(multiSessionProvider.select((s) => s.byId(groupId)));
  return ApiClient(
    baseUrl: g?.baseUrl ?? '',
    token: g?.token,
    onUnauthorized: () => ref.read(multiSessionProvider.notifier).signOutGroup(groupId),
  );
});

/// The account for "the current group" — the active one, or the first signed-in group
/// while viewing All. Screens that are inherently single-group (profile, admin,
/// settings, search) hang off this.
final currentAccountProvider = Provider<ServerAccount?>((ref) {
  return ref.watch(multiSessionProvider).current;
});

/// ApiClient for the current group (see [currentAccountProvider]). The single-group
/// screens keep reading this exactly like the old single-session apiProvider.
final apiProvider = Provider<ApiClient>((ref) {
  final acct = ref.watch(currentAccountProvider);
  if (acct == null) return ApiClient(baseUrl: '');
  return ref.watch(apiForGroupProvider(acct.id));
});

/// Resolves the account that owns a piece of content tagged with [groupId] (see
/// Post.groupId). Null falls back to the current group, so single-group screens work
/// unchanged.
final contentAccountProvider = Provider.family<ServerAccount?, String?>((ref, groupId) {
  if (groupId != null) {
    final g = ref.watch(multiSessionProvider.select((s) => s.byId(groupId)));
    if (g != null) return g;
  }
  return ref.watch(currentAccountProvider);
});

/// ApiClient for content from [groupId] — likes, comments, images on a post must hit
/// the server the post lives on, which in the All view differs per post.
final contentApiProvider = Provider.family<ApiClient, String?>((ref, groupId) {
  final acct = ref.watch(contentAccountProvider(groupId));
  if (acct == null) return ApiClient(baseUrl: '');
  return ref.watch(apiForGroupProvider(acct.id));
});

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

/// The location filter applied to the home feed — null means all places. Only applies
/// to a single group's feed (the filter is hidden in the All view).
final feedLocationProvider = StateProvider<String?>((ref) => null);

/// What the feed shows: the merged posts plus which groups couldn't be reached (All
/// view only), so the feed can degrade gracefully instead of failing whole.
class FeedResult {
  const FeedResult({required this.posts, this.unreachable = const []});

  final List<Post> posts;
  final List<ServerAccount> unreachable;
}

/// Merges per-group feed pages into one list, newest first. Ties break on post id so
/// the order is stable across refreshes.
List<Post> mergeFeeds(Iterable<List<Post>> pages) {
  final merged = [for (final page in pages) ...page];
  merged.sort((a, b) {
    final byTime = b.createdAt.compareTo(a.createdAt);
    return byTime != 0 ? byTime : b.id.compareTo(a.id);
  });
  return merged;
}

/// The home feed as a refreshable provider. Invalidate it (e.g. after creating a post)
/// and the feed list updates without a manual pull-to-refresh. Single group → that
/// group's feed (with the location filter); All view → the first page of every
/// signed-in group's feed, merged by time and tagged with its origin group.
final feedProvider = FutureProvider.autoDispose<FeedResult>((ref) async {
  final session = ref.watch(multiSessionProvider);
  if (!session.isAllView) {
    final acct = session.current;
    if (acct == null || !acct.isSignedIn) return const FeedResult(posts: []);
    final location = ref.watch(feedLocationProvider);
    final posts = await ref.watch(apiForGroupProvider(acct.id)).feed(location: location);
    return FeedResult(posts: [for (final p in posts) p.withGroup(acct.id)]);
  }

  final groups = session.signedIn;
  final pages = await Future.wait([
    for (final g in groups)
      ref
          .watch(apiForGroupProvider(g.id))
          .feed()
          .then<List<Post>?>((posts) => [for (final p in posts) p.withGroup(g.id)])
          .catchError((_) => null),
  ]);
  final unreachable = <ServerAccount>[];
  final loaded = <List<Post>>[];
  for (var i = 0; i < groups.length; i++) {
    final page = pages[i];
    if (page == null) {
      unreachable.add(groups[i]);
    } else {
      loaded.add(page);
    }
  }
  return FeedResult(posts: mergeFeeds(loaded), unreachable: unreachable);
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

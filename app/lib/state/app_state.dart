import 'dart:convert';
import 'dart:ui' show Color;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/accent.dart';
import '../theme/group_color.dart';

/// One connected group: a Check-In server plus this device's account on it. Because
/// every group is a physically separate server, identity (user id, photo, token) is
/// always per-group.
class ServerAccount {
  const ServerAccount({
    required this.id,
    required this.baseUrl,
    required this.serverName,
    this.nickname,
    this.color,
    this.token,
    this.user,
    this.mediaTypes = const ['image'],
    this.gifSearch = false,
    this.commentMedia = false,
    this.recapCapable = false,
    this.memoriesCapable = false,
    this.eventsCapable = false,
    this.timelineCapable = false,
    this.forgottenCapable = false,
    this.placesCapable = false,
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

  /// The group's admin-set palette color id (shared by every member), refreshed from
  /// server-info. Empty/null falls back to a deterministic color in [displayColor].
  final String? color;

  final String? token;

  /// The signed-in user on this server. Fetched lazily after restore, so it can be
  /// null for a moment (or while the server is unreachable) even when signed in.
  final User? user;

  /// What this group's server accepts as an attachment ('image', 'gif', 'video'), from its
  /// server-info. A server predating typed media says nothing and only ever took stills, so
  /// the default is images-only. Compose reads it to hide a clip option a group would reject.
  final List<String> mediaTypes;

  /// Whether this group's server can search gifs (its Klipy key is configured), from its
  /// server-info. Gates the gif icon in compose and comments.
  final bool gifSearch;

  /// Whether this group's server accepts a gif attachment on a comment, from its
  /// server-info. An older server predates the field entirely (see [ServerInfo.commentMedia])
  /// and defaults to false, so the client never sends it a `mediaId` it would 400 on.
  final bool commentMedia;

  /// Whether this group's server understands the recap feature (see
  /// [ServerInfo.recapCapable]). Gates sending lat/lng on createPost, sending the recap
  /// fields on PATCH /api/admin/server, and showing the recap settings UI at all - a server
  /// predating the feature rejects unknown JSON fields, so guessing wrong would break
  /// posting entirely rather than just hiding a screen.
  final bool recapCapable;

  /// Whether this group's server has GET /api/memories/random (see
  /// [ServerInfo.memoriesCapable]). Gates showing the Memories grab handle at all - an older
  /// server has no such route and would 404 the request.
  final bool memoriesCapable;

  /// Whether this group's server has GET /api/memories/events (see
  /// [ServerInfo.eventsCapable]). Gates showing the "You were there" hub entry - an older
  /// server has no such route and would 404 the request.
  final bool eventsCapable;

  /// Whether this group's server has GET /api/memories/timeline (see
  /// [ServerInfo.timelineCapable]). Gates showing the "Your months" hub entry - an older
  /// server has no such route and would 404 the request.
  final bool timelineCapable;

  /// Whether this group's server has GET /api/memories/forgotten (see
  /// [ServerInfo.forgottenCapable]). Gates showing the "Forgotten photos" hub entry - an
  /// older server has no such route and would 404 the request.
  final bool forgottenCapable;

  /// Whether this group's server has GET /api/memories/places (see
  /// [ServerInfo.placesCapable]). Gates showing the "Places" hub entry - an older server
  /// has no such route and would 404 the request.
  final bool placesCapable;

  bool get isSignedIn => token != null;

  /// What the UI calls this group: the local nickname when set, else the server's name.
  String get displayName {
    final n = nickname;
    return (n == null || n.isEmpty) ? serverName : n;
  }

  /// The group's color in the merged feed: the admin-set palette color, else a
  /// deterministic color from the group id so groups are still told apart.
  Color get displayColor => groupColorById(color) ?? groupColorFor(id);

  ServerAccount copyWith({
    String? serverName,
    String? nickname,
    bool clearNickname = false,
    String? color,
    bool clearColor = false,
    String? token,
    User? user,
    bool clearAuth = false,
    List<String>? mediaTypes,
    bool? gifSearch,
    bool? commentMedia,
    bool? recapCapable,
    bool? memoriesCapable,
    bool? eventsCapable,
    bool? timelineCapable,
    bool? forgottenCapable,
    bool? placesCapable,
  }) {
    return ServerAccount(
      id: id,
      baseUrl: baseUrl,
      serverName: serverName ?? this.serverName,
      nickname: clearNickname ? null : (nickname ?? this.nickname),
      color: clearColor ? null : (color ?? this.color),
      token: clearAuth ? null : (token ?? this.token),
      user: clearAuth ? null : (user ?? this.user),
      mediaTypes: mediaTypes ?? this.mediaTypes,
      gifSearch: gifSearch ?? this.gifSearch,
      commentMedia: commentMedia ?? this.commentMedia,
      recapCapable: recapCapable ?? this.recapCapable,
      memoriesCapable: memoriesCapable ?? this.memoriesCapable,
      eventsCapable: eventsCapable ?? this.eventsCapable,
      timelineCapable: timelineCapable ?? this.timelineCapable,
      forgottenCapable: forgottenCapable ?? this.forgottenCapable,
      placesCapable: placesCapable ?? this.placesCapable,
    );
  }
}

/// The app-level session: every connected group plus which ones the feed shows.
/// [hiddenGroupIds] holds the groups toggled off in the group bubble; empty means every
/// group is shown (the combined "All groups" view).
class MultiSession {
  const MultiSession({
    this.groups = const [],
    this.hiddenGroupIds = const {},
    this.restored = false,
  });

  final List<ServerAccount> groups;

  /// Groups the user has toggled off in the feed. Empty = show every group (All view).
  final Set<String> hiddenGroupIds;

  /// True once persisted state has been loaded (so startup can tell "no groups yet"
  /// from "still restoring").
  final bool restored;

  List<ServerAccount> get signedIn => [
        for (final g in groups)
          if (g.isSignedIn) g
      ];

  /// Groups still on this device whose token is gone. A 401 means an expired session, but
  /// it means exactly the same thing when the host removed you or the server is gone for
  /// good, so these need a way out as well as a way back in.
  List<ServerAccount> get signedOut => [
        for (final g in groups)
          if (!g.isSignedIn) g
      ];

  bool get anySignedIn => groups.any((g) => g.isSignedIn);

  ServerAccount? byId(String? id) {
    if (id == null) return null;
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Signed-in groups currently visible in the feed: all minus the hidden ones. May be
  /// empty - the user can toggle every group off; the feed then shows a "no groups shown"
  /// state instead of fighting the selection.
  List<ServerAccount> get shownGroups => [
        for (final g in signedIn)
          if (!hiddenGroupIds.contains(g.id)) g
      ];

  /// Every group is toggled off (only meaningful when signed in somewhere).
  bool get nothingShown => signedIn.isNotEmpty && shownGroups.isEmpty;

  /// The single group in focus when exactly one is shown; null when zero or many.
  ServerAccount? get soleShown => shownGroups.length == 1 ? shownGroups.first : null;

  /// The account backing screens that need "the current group" (profile, admin,
  /// settings, search): the sole shown group, or the first signed-in one otherwise.
  ServerAccount? get current {
    final one = soleShown;
    if (one != null) return one;
    if (signedIn.isNotEmpty) return signedIn.first;
    return groups.isNotEmpty ? groups.first : null;
  }

  /// Exactly one group shown → per-group search + filters + pagination apply.
  bool get isSingleGroupView => shownGroups.length == 1;

  /// More than one group shown → the merged feed (per-group origin colors, no per-group
  /// search/filter).
  bool get isAllView => shownGroups.length > 1;

  /// Whether nothing is hidden (every signed-in group is shown). Only meaningful with more
  /// than one signed-in group.
  bool get showingAll => signedIn.length > 1 && shownGroups.length == signedIn.length;

  /// The shown groups whose server advertises the Memories capability - what the hidden
  /// surface draws from. A group that predates the feature (or a signed-out one) never
  /// contributes a memory, the same way it's excluded from [shownGroups] once signed out.
  List<ServerAccount> get memoriesCapableShownGroups => [
        for (final g in shownGroups)
          if (g.memoriesCapable) g
      ];

  /// The shown groups whose server advertises the Events capability - what the "You were
  /// there" hub entry draws from. Independent of [memoriesCapableShownGroups]: a server can
  /// have one capability without the other.
  List<ServerAccount> get eventsCapableShownGroups => [
        for (final g in shownGroups)
          if (g.eventsCapable) g
      ];

  /// The shown groups whose server advertises the Timeline capability - what the "Month by
  /// month" hub entry draws from. Independent of the other two hub-entry capabilities: a
  /// server can have any subset of them.
  List<ServerAccount> get timelineCapableShownGroups => [
        for (final g in shownGroups)
          if (g.timelineCapable) g
      ];

  /// The shown groups whose server advertises the Forgotten-photos capability - what the
  /// "Forgotten photos" hub entry draws from. Independent of the other three: a server can
  /// have any subset of them.
  List<ServerAccount> get forgottenCapableShownGroups => [
        for (final g in shownGroups)
          if (g.forgottenCapable) g
      ];

  /// The shown groups whose server advertises the Places capability - what the "Places"
  /// hub entry draws from. Independent of the other four: a server can have any subset of
  /// them.
  List<ServerAccount> get placesCapableShownGroups => [
        for (final g in shownGroups)
          if (g.placesCapable) g
      ];

  /// The shown groups capable of at least one Memories-surface feature (memories, events,
  /// timeline, forgotten, or places) - the option set for the Memories surface's own group
  /// selector (see memories_screen.dart's header). A group need not have every capability
  /// to appear here; which of the surface's five views it actually offers is decided
  /// per-group once it's the selected one (see effectiveMemoriesGroupId and
  /// _MemoriesHubHome).
  List<ServerAccount> get memoriesSurfaceCapableShownGroups => [
        for (final g in shownGroups)
          if (g.memoriesCapable ||
              g.eventsCapable ||
              g.timelineCapable ||
              g.forgottenCapable ||
              g.placesCapable)
            g
      ];

  /// Default cross-post targets for a new check-in: the groups currently in view
  /// ("post where you're looking"), or every signed-in group when the feed selection is
  /// empty. The compose sheet shows the choice prominently, so the default is one tap to
  /// change.
  List<ServerAccount> get composeDefaults => shownGroups.isNotEmpty ? shownGroups : signedIn;
}

const _kGroups = 'groups_json';
const _kHiddenGroups = 'hidden_group_ids'; // JSON list of groups toggled off; [] = All
// Retired single-select key, migrated into [_kHiddenGroups] on first launch of this build.
const _kActiveGroup = 'active_group_id';
// Pre-multi-group keys, migrated into the group list on first launch of this build.
const _kLegacyBaseUrl = 'base_url';
const _kLegacyToken = 'token';

/// MultiSessionController loads and persists every group session across launches.
/// Tokens live in secure storage (keyed per group); the non-secret group list lives in
/// shared preferences.
class MultiSessionController extends Notifier<MultiSession> {
  MultiSessionController() : _seed = null;

  /// Starts from a fixed state and skips restore/hydration - for widget tests.
  @visibleForTesting
  MultiSessionController.seeded(MultiSession initial) : _seed = initial;

  final MultiSession? _seed;

  final _secure = const FlutterSecureStorage();

  @override
  MultiSession build() {
    final seed = _seed;
    if (seed != null) return seed;
    // Restore reads storage and so can't be synchronous. Start from the empty session -
    // whose `restored: false` is exactly what startup shows as "still restoring" - and swap
    // the stored one in when it lands.
    _load();
    return const MultiSession();
  }

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
        entries = [
          (
            id: id,
            baseUrl: legacyUrl,
            name: 'Check-In',
            nickname: null,
            color: null,
            mediaTypes: const ['image'],
            gifSearch: false,
            commentMedia: false,
            recapCapable: false,
            memoriesCapable: false,
            eventsCapable: false,
            timelineCapable: false,
            forgottenCapable: false,
            placesCapable: false,
          )
        ];
        await prefs.setString(_kGroups, _encodeGroups(entries));
        await prefs.remove(_kLegacyBaseUrl);
        await _secure.delete(key: _kLegacyToken);
      }
    }

    final accounts = <ServerAccount>[];
    for (final e in entries) {
      final token = await _secure.read(key: _tokenKey(e.id));
      accounts.add(ServerAccount(
          id: e.id,
          baseUrl: e.baseUrl,
          serverName: e.name,
          nickname: e.nickname,
          color: e.color,
          mediaTypes: e.mediaTypes,
          gifSearch: e.gifSearch,
          commentMedia: e.commentMedia,
          recapCapable: e.recapCapable,
          memoriesCapable: e.memoriesCapable,
          eventsCapable: e.eventsCapable,
          timelineCapable: e.timelineCapable,
          forgottenCapable: e.forgottenCapable,
          placesCapable: e.placesCapable,
          token: token));
    }
    final ids = {for (final g in accounts) g.id};
    var hidden = <String>{};
    final rawHidden = prefs.getString(_kHiddenGroups);
    if (rawHidden != null) {
      hidden = _decodeHidden(rawHidden).where(ids.contains).toSet();
    } else {
      // Migrate the retired single-select `active_group_id`: a specific group meant "show
      // only that one" → hide the others; '' / absent meant All → hide nothing.
      final oldActive = prefs.getString(_kActiveGroup);
      if (oldActive != null && oldActive.isNotEmpty && ids.contains(oldActive)) {
        hidden = {
          for (final id in ids)
            if (id != oldActive) id
        };
      }
      await prefs.setString(_kHiddenGroups, _encodeHidden(hidden));
      await prefs.remove(_kActiveGroup);
    }
    state = MultiSession(groups: accounts, hiddenGroupIds: hidden, restored: true);

    // Hydrate each signed-in group's user (and refresh its display name) in parallel.
    for (final g in accounts) {
      if (g.isSignedIn) _hydrate(g);
    }
  }

  /// Validates a restored token by fetching the current user, and refreshes the group's
  /// display name. Only a real auth rejection drops the token - a network/timeout error
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
      final nameChanged = info.name.isNotEmpty && info.name != g.serverName;
      final colorChanged = info.color != (g.color ?? '');
      final mediaChanged = !listEquals(info.mediaTypes, g.mediaTypes);
      final gifChanged = info.gifSearch != g.gifSearch || info.commentMedia != g.commentMedia;
      final recapChanged = info.recapCapable != g.recapCapable;
      final memoriesChanged = info.memoriesCapable != g.memoriesCapable;
      final eventsChanged = info.eventsCapable != g.eventsCapable;
      final timelineChanged = info.timelineCapable != g.timelineCapable;
      final forgottenChanged = info.forgottenCapable != g.forgottenCapable;
      final placesChanged = info.placesCapable != g.placesCapable;
      if (nameChanged ||
          colorChanged ||
          mediaChanged ||
          gifChanged ||
          recapChanged ||
          memoriesChanged ||
          eventsChanged ||
          timelineChanged ||
          forgottenChanged ||
          placesChanged) {
        _update(
            g.id,
            (a) => a.copyWith(
                  serverName: nameChanged ? info.name : null,
                  color: info.color,
                  clearColor: info.color.isEmpty,
                  mediaTypes: info.mediaTypes,
                  gifSearch: info.gifSearch,
                  commentMedia: info.commentMedia,
                  recapCapable: info.recapCapable,
                  memoriesCapable: info.memoriesCapable,
                  eventsCapable: info.eventsCapable,
                  timelineCapable: info.timelineCapable,
                  forgottenCapable: info.forgottenCapable,
                  placesCapable: info.placesCapable,
                ));
        await _persistGroups();
      }
    } catch (_) {
      // Name/color refresh is cosmetic; ignore failures.
    }
  }

  void _update(String id, ServerAccount Function(ServerAccount) fn) {
    state = MultiSession(
      groups: [
        for (final g in state.groups)
          if (g.id == id) fn(g) else g
      ],
      hiddenGroupIds: state.hiddenGroupIds,
      restored: state.restored,
    );
  }

  Future<void> _persistGroups() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kGroups,
      _encodeGroups([
        for (final g in state.groups)
          (
            id: g.id,
            baseUrl: g.baseUrl,
            name: g.serverName,
            nickname: g.nickname,
            color: g.color,
            mediaTypes: g.mediaTypes,
            gifSearch: g.gifSearch,
            commentMedia: g.commentMedia,
            recapCapable: g.recapCapable,
            memoriesCapable: g.memoriesCapable,
            eventsCapable: g.eventsCapable,
            timelineCapable: g.timelineCapable,
            forgottenCapable: g.forgottenCapable,
            placesCapable: g.placesCapable,
          )
      ]),
    );
  }

  Future<void> _persistHidden() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHiddenGroups, _encodeHidden(state.hiddenGroupIds));
  }

  /// Connects (or re-connects) a group after a successful login/signup and makes it
  /// active. Re-adding an existing group replaces its entry (the re-login path).
  Future<void> addGroup({
    required String baseUrl,
    required String serverName,
    required String token,
    required User user,
    String? color,
  }) async {
    final id = groupIdFor(baseUrl);
    await _secure.write(key: _tokenKey(id), value: token);
    final account = ServerAccount(
        id: id, baseUrl: baseUrl, serverName: serverName, color: color, token: token, user: user);
    final others = [
      for (final g in state.groups)
        if (g.id != id) g
    ];
    // A newly connected (or re-logged-in) group is always shown.
    state = MultiSession(
      groups: [...others, account],
      hiddenGroupIds: state.hiddenGroupIds.difference({id}),
      restored: state.restored,
    );
    await _persistGroups();
    await _persistHidden();
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
    state = MultiSession(
      groups: groups,
      hiddenGroupIds: state.hiddenGroupIds.difference({id}),
      restored: state.restored,
    );
    await _persistGroups();
    await _persistHidden();
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

  /// Records a new server-side name after an admin rename, so it shows immediately
  /// without waiting for the next hydrate. Clears any local nickname so the group falls
  /// back to showing the (now-updated) server name.
  Future<void> applyServerName(String id, String name) async {
    _update(id, (g) => g.copyWith(serverName: name, clearNickname: true));
    await _persistGroups();
  }

  /// Records a new server-side color after an admin picks one, so it shows immediately
  /// without waiting for the next hydrate. An empty id clears back to the automatic color.
  Future<void> applyServerColor(String id, String colorId) async {
    _update(id, (g) => g.copyWith(color: colorId, clearColor: colorId.isEmpty));
    await _persistGroups();
  }

  /// Shows every group again (clears the hidden set): the combined All view.
  Future<void> showAllGroups() async {
    if (state.hiddenGroupIds.isEmpty) return;
    state = MultiSession(groups: state.groups, hiddenGroupIds: const {}, restored: state.restored);
    await _persistHidden();
  }

  /// Toggles a group's visibility in the feed. Hiding every group is allowed - the feed
  /// shows an explicit "no groups shown" state rather than blocking the toggle.
  Future<void> toggleGroup(String id) async {
    final hidden = {...state.hiddenGroupIds};
    if (!hidden.remove(id)) hidden.add(id);
    state = MultiSession(groups: state.groups, hiddenGroupIds: hidden, restored: state.restored);
    await _persistHidden();
  }

  /// Replaces the hidden set wholesale (the filter sheet applies its GROUPS selection in
  /// one go). Unknown ids are dropped so a stale sheet can't hide ghosts.
  Future<void> setHiddenGroups(Set<String> ids) async {
    final known = {for (final g in state.groups) g.id};
    final hidden = ids.where(known.contains).toSet();
    if (setEquals(hidden, state.hiddenGroupIds)) return;
    state = MultiSession(groups: state.groups, hiddenGroupIds: hidden, restored: state.restored);
    await _persistHidden();
  }

  /// Ensures a group is visible in the feed (used when a push tap lands you in it).
  Future<void> showGroup(String id) async {
    if (!state.hiddenGroupIds.contains(id)) return;
    final hidden = {...state.hiddenGroupIds}..remove(id);
    state = MultiSession(groups: state.groups, hiddenGroupIds: hidden, restored: state.restored);
    await _persistHidden();
  }

  /// Refreshes the cached user for a group (e.g. after editing the profile there).
  void updateUser(String groupId, User user) {
    _update(groupId, (g) => g.copyWith(user: user));
  }

  static List<
      ({
        String id,
        String baseUrl,
        String name,
        String? nickname,
        String? color,
        List<String> mediaTypes,
        bool gifSearch,
        bool commentMedia,
        bool recapCapable,
        bool memoriesCapable,
        bool eventsCapable,
        bool timelineCapable,
        bool forgottenCapable,
        bool placesCapable
      })> _decodeGroups(String? raw) {
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
            color: e['color'] as String?,
            // Absent (an older stored entry) means the last-known types are unknown, so fall
            // back to images-only; the next hydrate refreshes it from server-info.
            mediaTypes:
                (e['mediaTypes'] as List?)?.map((t) => t as String).toList() ?? const ['image'],
            // Same reasoning as mediaTypes: absent means "unknown, assume off" until the next
            // hydrate refreshes it from server-info.
            gifSearch: e['gifSearch'] as bool? ?? false,
            commentMedia: e['commentMedia'] as bool? ?? false,
            // Same story: absent means unknown, not capable - the next hydrate refreshes it.
            recapCapable: e['recapCapable'] as bool? ?? false,
            memoriesCapable: e['memoriesCapable'] as bool? ?? false,
            eventsCapable: e['eventsCapable'] as bool? ?? false,
            timelineCapable: e['timelineCapable'] as bool? ?? false,
            // Same story as the others: absent (an entry stored before this capability
            // existed) means unknown, not capable - the next hydrate refreshes it.
            forgottenCapable: e['forgottenCapable'] as bool? ?? false,
            placesCapable: e['placesCapable'] as bool? ?? false,
          )
      ];
    } catch (_) {
      return const [];
    }
  }

  static String _encodeGroups(
      List<
              ({
                String id,
                String baseUrl,
                String name,
                String? nickname,
                String? color,
                List<String> mediaTypes,
                bool gifSearch,
                bool commentMedia,
                bool recapCapable,
                bool memoriesCapable,
                bool eventsCapable,
                bool timelineCapable,
                bool forgottenCapable,
                bool placesCapable
              })>
          entries) {
    return jsonEncode([
      for (final e in entries)
        {
          'id': e.id,
          'baseUrl': e.baseUrl,
          'name': e.name,
          if (e.nickname != null) 'nickname': e.nickname,
          if (e.color != null && e.color!.isNotEmpty) 'color': e.color,
          'mediaTypes': e.mediaTypes,
          'gifSearch': e.gifSearch,
          'commentMedia': e.commentMedia,
          'recapCapable': e.recapCapable,
          'memoriesCapable': e.memoriesCapable,
          'eventsCapable': e.eventsCapable,
          'timelineCapable': e.timelineCapable,
          'forgottenCapable': e.forgottenCapable,
          'placesCapable': e.placesCapable,
        }
    ]);
  }

  static Set<String> _decodeHidden(String raw) {
    try {
      return {for (final e in jsonDecode(raw) as List) e as String};
    } catch (_) {
      return {};
    }
  }

  static String _encodeHidden(Set<String> ids) => jsonEncode(ids.toList());
}

final multiSessionProvider =
    NotifierProvider<MultiSessionController, MultiSession>(MultiSessionController.new);

/// An ApiClient bound to one group. A 401 there signs out ONLY that group - the other
/// groups' sessions (and the shared image cache) stay intact.
final apiForGroupProvider = Provider.family<ApiClient, String>((ref, groupId) {
  final g = ref.watch(multiSessionProvider.select((s) => s.byId(groupId)));
  return ApiClient(
    baseUrl: g?.baseUrl ?? '',
    token: g?.token,
    onUnauthorized: () => ref.read(multiSessionProvider.notifier).signOutGroup(groupId),
  );
});

/// The account for "the current group" - the active one, or the first signed-in group
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

/// ApiClient for content from [groupId] - likes, comments, images on a post must hit
/// the server the post lives on, which in the All view differs per post.
final contentApiProvider = Provider.family<ApiClient, String?>((ref, groupId) {
  final acct = ref.watch(contentAccountProvider(groupId));
  if (acct == null) return ApiClient(baseUrl: '');
  return ref.watch(apiForGroupProvider(acct.id));
});

/// The viewer's like on each post, held app-wide so it survives navigation and is the one
/// source of truth every screen reads. Keyed "$groupId:$postId"; the value is the viewer's
/// intended liked-state, and an absent key means "use whatever the server last returned".
/// Before this, the feed card and the post screen each kept their own like state, so a like
/// made in one place was invisible in the other and was lost the moment a widget rebuilt.
class LikesController extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  static String _key(String? groupId, int postId) => '$groupId:$postId';

  /// The overlay's view of one post, falling back to the server's value when untouched.
  bool likedFor(String? groupId, int postId, bool serverLiked) =>
      state[_key(groupId, postId)] ?? serverLiked;

  /// Optimistically records the like, then tells the server; on failure it rolls the entry
  /// back to what it was so a dropped request can't leave a wrong heart on screen.
  Future<void> setLiked(String? groupId, int postId, bool wantLike) async {
    final key = _key(groupId, postId);
    final prev = state[key];
    if (prev == wantLike) return;
    state = {...state, key: wantLike};
    try {
      final api = ref.read(contentApiProvider(groupId));
      wantLike ? await api.like(postId) : await api.unlike(postId);
    } catch (_) {
      final next = {...state};
      if (prev == null) {
        next.remove(key);
      } else {
        next[key] = prev;
      }
      state = next;
    }
  }
}

final likesProvider = NotifierProvider<LikesController, Map<String, bool>>(LikesController.new);

/// The heart state and count to render for [post], applying the viewer's like overlay on
/// top of the server counts. The count is carried as a delta from the server's own value,
/// so a like landing from someone else (which raises the server count) still shows right.
/// A cross-post reads as liked only when every copy is liked, and sums each copy's delta -
/// minus a correction for the viewer's own like: liking a cross-post likes every copy the
/// viewer can reach (see _toggleLike), so a viewer who is in more than one group it was
/// shared to is a real liker on each of those copies. They are still one person, so summing
/// raw per-copy counts would count that one like once per group they happen to share with
/// the poster. This corrects the viewer's own contribution precisely (their per-copy liked
/// state is exact); it does not dedupe some *other* member who independently belongs to
/// several of the same groups and liked in each - that would need cross-referencing every
/// copy's full liker list against phone identity (PersonDirectory), which is unrelated in
/// cost to just rendering a post and not done here.
({bool liked, int likes}) likeView(Post post, Map<String, bool> overlay) {
  if (post.isCrossPost) {
    var liked = true;
    var likes = 0;
    var likedCopies = 0;
    for (final c in post.copies) {
      final l = overlay['${c.groupId}:${c.postId}'] ?? c.likedByViewer;
      if (!l) liked = false;
      if (l) likedCopies++;
      likes += c.likeCount + (l ? 1 : 0) - (c.likedByViewer ? 1 : 0);
    }
    if (likedCopies > 1) likes -= likedCopies - 1;
    return (liked: liked, likes: likes);
  }
  final l = overlay['${post.groupId}:${post.id}'] ?? post.likedByViewer;
  return (liked: l, likes: post.likeCount + (l ? 1 : 0) - (post.likedByViewer ? 1 : 0));
}

const _kAccentId = 'accent_id';

/// The user's chosen accent palette, persisted per-device. Drives the whole app
/// theme via [AccentPalette] on [ThemeData].
class AccentController extends Notifier<AccentPalette> {
  @override
  AccentPalette build() {
    // Preferences are async, so the stored choice can't be the initial value; the app wears
    // the default palette for the frame or two before it arrives.
    _load();
    return kAccentPresets.first;
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

final accentProvider = NotifierProvider<AccentController, AccentPalette>(AccentController.new);

/// Whether signup should offer the accent picker, given whether this device already has
/// groups connected. The accent is one per-device theme, and the picker persists the
/// instant a swatch is tapped, so offering it on a later group join lets that join
/// silently replace a color the user has been living with.
///
/// Both conditions carry weight. A stored accent alone would re-ask someone who signed up
/// once and never touched the swatches; connected groups alone would ask someone whose
/// first-ever action was logging in to an existing account, since that path skips signup
/// entirely. Together they mean "this device has never been through signup".
///
/// This reads preferences rather than [accentProvider] because [AccentController] resolves
/// a missing value through [accentById] to the first preset, so its state can't tell
/// "never chose" from "chose green".
Future<bool> shouldPromptForAccent({required bool hasGroups}) async {
  if (hasGroups) return false;
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kAccentId) == null;
}

const _kClipsMuted = 'feed_autoplay_muted';

/// Whether clips play muted, remembered per-device.
///
/// Clips autoplay with sound the way Reels does, and a silenced phone stays silent without
/// the app deciding anything: the ambient audio session hands that to the Ring/Silent switch
/// (see `VideoNative.respectSilentSwitch`). This is the choice that sits on top of the
/// switch - one sticky mute shared by the feed tiles and the full-screen viewer, so muting a
/// clip anywhere keeps every later clip muted until it is turned back on.
class ClipMuteController extends Notifier<bool> {
  @override
  bool build() {
    // Preferences are async, so the stored choice lands a frame or two in. No clip can
    // autoplay that early - the feed has to load first - so nothing is heard before it.
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_kClipsMuted) ?? false;
  }

  Future<void> toggle() => setMuted(!state);

  Future<void> setMuted(bool muted) async {
    state = muted;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kClipsMuted, muted);
  }
}

final clipsMutedProvider = NotifierProvider<ClipMuteController, bool>(ClipMuteController.new);

/// The location filter applied to the home feed - empty means all places. Only applies
/// to a single group's feed (the filter is hidden in the All view).
class FeedLocationFilter extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Replaces the selection wholesale (the filter sheet applies its PLACES picks in one go).
  void apply(Set<String> locations) => state = locations;
}

final feedLocationProvider =
    NotifierProvider<FeedLocationFilter, Set<String>>(FeedLocationFilter.new);

/// Bumped whenever the viewer creates a check-in. The profile tab lives in an always-alive
/// IndexedStack, so it can't notice new posts on its own; it listens to this and reloads,
/// which is why a just-posted check-in now shows up when you switch to your profile.
class ProfileRefresh extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final profileRefreshProvider = NotifierProvider<ProfileRefresh, int>(ProfileRefresh.new);

/// What the feed shows: the merged posts plus which groups couldn't be reached (All
/// view only), so the feed can degrade gracefully instead of failing whole.
class FeedResult {
  const FeedResult({required this.posts, this.unreachable = const []});

  final List<Post> posts;
  final List<ServerAccount> unreachable;
}

/// Merges per-group feed pages into one list, newest first, collapsing any post shared to
/// several shown groups into a single card. Ties break on post id so the order is stable
/// across refreshes.
List<Post> mergeFeeds(Iterable<List<Post>> pages) {
  final merged = collapseCrossPosts([for (final page in pages) ...page]);
  merged.sort((a, b) {
    final byTime = b.createdAt.compareTo(a.createdAt);
    return byTime != 0 ? byTime : b.id.compareTo(a.id);
  });
  return merged;
}

/// Collapses posts sharing a [Post.crossPostId] into one card carrying every copy the
/// viewer can see (each on its own group's server). A copy only appears here if the viewer
/// is in that group, so a single-group member's app never has more than one copy and sees
/// nothing merged - the per-group isolation is enforced by which servers they can reach,
/// not by a permission check. The newest copy stands in as the representative.
List<Post> collapseCrossPosts(List<Post> posts) {
  final groups = <String, List<Post>>{};
  final out = <Post>[];
  for (final p in posts) {
    final id = p.crossPostId;
    if (id == null || p.groupId == null) {
      out.add(p);
      continue;
    }
    (groups[id] ??= []).add(p);
  }
  for (final entry in groups.values) {
    if (entry.length == 1) {
      out.add(entry.first);
      continue;
    }
    entry.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final copies = [
      for (final p in entry)
        (
          groupId: p.groupId!,
          postId: p.id,
          likeCount: p.likeCount,
          commentCount: p.commentCount,
          likedByViewer: p.likedByViewer,
        ),
    ];
    out.add(entry.first.withCopies(copies));
  }
  return out;
}

/// The home feed as a refreshable provider. Invalidate it (e.g. after creating a post)
/// and the feed list updates without a manual pull-to-refresh. One group shown → that
/// group's feed (with the location filter); more than one → the first page of every shown
/// group's feed, merged by time and tagged with its origin group.
final feedProvider = FutureProvider.autoDispose<FeedResult>((ref) async {
  final session = ref.watch(multiSessionProvider);
  final groups = session.shownGroups;
  final locations = ref.watch(feedLocationProvider);
  if (groups.isEmpty) return const FeedResult(posts: []);
  if (groups.length == 1) {
    final acct = groups.first;
    final posts = await ref.watch(apiForGroupProvider(acct.id)).feed(locations: locations);
    return FeedResult(posts: [for (final p in posts) p.withGroup(acct.id)]);
  }

  // The place filter applies per group; groups without any selected place just contribute
  // nothing.
  final pages = await Future.wait([
    for (final g in groups)
      ref
          .watch(apiForGroupProvider(g.id))
          .feed(locations: locations)
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

/// Distinct place labels for one group's check-ins (most-used first). The place filter
/// merges these across every shown group.
final locationsProvider =
    FutureProvider.autoDispose.family<List<({String location, int count})>, String>((ref, groupId) {
  return ref.watch(apiForGroupProvider(groupId)).locations();
});

/// One group's member list (used to join the same person across groups by phone in the
/// People filter, and for their profile photos there). An empty query returns every active
/// member - the same data the tag-people picker already reads - with each carrying
/// [User.phoneKey] rather than their real number (see its doc comment).
final groupMembersProvider = FutureProvider.autoDispose.family<List<User>, String>((ref, groupId) {
  return ref.watch(apiForGroupProvider(groupId)).searchUsers('');
});

const _kTermsAccepted = 'terms_accepted';

/// Tracks whether the user has accepted the in-app terms of service. Checked before
/// the auth screen so the EULA is presented on first launch (Apple Guideline 1.2).
class TermsController extends Notifier<bool> {
  @override
  bool build() {
    // Preferences are async, so start from "not accepted": erring towards showing the gate
    // again is recoverable, erring towards skipping it is what Apple rejected the app for.
    _load();
    return false;
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

final termsProvider = NotifierProvider<TermsController, bool>(TermsController.new);

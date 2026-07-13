import 'package:shared_preferences/shared_preferences.dart';

/// Per-group high-water mark: the timestamp of the newest check-in a member has already
/// been shown. The feed draws a "you're all caught up" line at the boundary between posts
/// newer than this and posts they've seen before.
///
/// Markers are per group because post ids are only unique per server, and a member can be
/// caught up in one group while behind in another.

String _key(String groupId) => 'feed_seen_at_$groupId';

/// Reads the seen-marker for each of [groupIds]. Groups with no marker are absent from the
/// result: a member who has never opened the feed has nothing to be "caught up" from, so
/// treating their whole first feed as unread would just be noise.
Future<Map<String, DateTime>> loadSeenMarkers(Iterable<String> groupIds) async {
  final prefs = await SharedPreferences.getInstance();
  final out = <String, DateTime>{};
  for (final id in groupIds) {
    final raw = prefs.getString(_key(id));
    if (raw == null) continue;
    final at = DateTime.tryParse(raw);
    if (at != null) out[id] = at;
  }
  return out;
}

/// Advances each group's marker to the newest post currently on show. Only ever moves
/// forward, so an older page loading in (or a group being briefly unreachable) can't drag
/// a member's "caught up" point backwards and resurface posts they've already seen.
Future<void> saveSeenMarkers(Map<String, DateTime> newest) async {
  if (newest.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  for (final e in newest.entries) {
    final raw = prefs.getString(_key(e.key));
    final prev = raw == null ? null : DateTime.tryParse(raw);
    if (prev != null && !e.value.isAfter(prev)) continue;
    await prefs.setString(_key(e.key), e.value.toUtc().toIso8601String());
  }
}

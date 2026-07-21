import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/person_directory.dart';
import '../../state/unread.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/date_range_sheet.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/user_avatar.dart';
import '../onboarding/auth_screen.dart';
import 'global_search_delegate.dart';
import 'post_card.dart';

/// Bumped when the user taps the Home tab while already on the feed; the feed listens and
/// animates back to the top. Tapping the status-bar strip does the same (see the tap-strip
/// in build) - we handle it explicitly rather than relying on iOS's native status-bar tap.
final feedScrollToTopProvider = StateProvider<int>((ref) => 0);

// Theme tokens (centralized in theme/tokens.dart).
const _bgMain = kBgMain;
const _bgSurface = kBgSurface;
const _bgSurfaceHover = kBgSurfaceHover;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;

const _datePresets = ['Today', 'This week', 'This month'];

/// The feed's active date filter: a named preset (re-evaluated against "now", so "Today"
/// keeps meaning today) or an explicit custom range. Its [matches] gate is shared by the
/// live feed filter and the bulk-download collector, so both agree on what's in range.
sealed class _DateFilter {
  const _DateFilter();

  /// Whether a post created at [created] (any timezone) falls inside the window.
  bool matches(DateTime created);

  /// Whether [oldest] is older than the window's earliest bound - so every still-older
  /// post is outside it too and paging (which runs newest-first) can stop.
  bool isPastWindow(DateTime oldest);

  /// Short label for the active-filter chip and the download summary.
  String get label;
}

/// One of [_datePresets], evaluated live relative to now.
class _PresetDate extends _DateFilter {
  const _PresetDate(this.preset);
  final String preset;

  @override
  bool matches(DateTime created) {
    final now = DateTime.now();
    final c = created.toLocal();
    return switch (preset) {
      'Today' => c.year == now.year && c.month == now.month && c.day == now.day,
      'This week' => now.difference(c).inDays < 7,
      'This month' => now.difference(c).inDays < 31,
      _ => true,
    };
  }

  // Posts are never in the future, so failing [matches] means older-than-window.
  @override
  bool isPastWindow(DateTime oldest) => !matches(oldest);

  @override
  String get label => preset;
}

/// An explicit [start]..[end] window (both inclusive; local day boundaries).
class _RangeDate extends _DateFilter {
  const _RangeDate(this.start, this.end);
  final DateTime start;
  final DateTime end;

  @override
  bool matches(DateTime created) {
    final c = created.toLocal();
    return !c.isBefore(start) && !c.isAfter(end);
  }

  @override
  bool isPastWindow(DateTime oldest) => oldest.toLocal().isBefore(start);

  @override
  String get label {
    final f = DateFormat.MMMd();
    final s = f.format(start);
    final e = f.format(end);
    return s == e ? s : '$s - $e';
  }
}

/// A feed item that renders the section date label with connector lines.
class _DateDivider extends StatelessWidget {
  const _DateDivider({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(width: 2, height: 12, color: context.accentLight),
        Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 4),
          decoration: BoxDecoration(
            color: _bgSurface,
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: _fgSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 11,
              letterSpacing: 0.3,
            ),
          ),
        ),
        Container(width: 2, height: 12, color: context.accentLight),
      ],
    );
  }
}

/// Vertical connector between posts: line → accent dot → line.
class _GapConnector extends StatelessWidget {
  const _GapConnector();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(width: 2, height: 11, color: context.accentLight),
        Container(
          width: 9,
          height: 9,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: context.accent,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: context.accentLight, blurRadius: 0, spreadRadius: 3)],
          ),
        ),
        Container(width: 2, height: 11, color: context.accentLight),
      ],
    );
  }
}

/// The boundary line between check-ins posted since the member's last visit and the ones
/// they've already seen. Everything above it is new.
class _CaughtUpDivider extends StatelessWidget {
  const _CaughtUpDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: context.accentLight)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 14, color: context.accent),
                const SizedBox(width: 6),
                Text("You're all caught up",
                    style: TextStyle(
                        color: context.accent, fontWeight: FontWeight.w600, fontSize: 12)),
              ],
            ),
          ),
          Expanded(child: Container(height: 1, color: context.accentLight)),
        ],
      ),
    );
  }
}

sealed class _FeedItem {}

class _DividerItem extends _FeedItem {
  _DividerItem(this.label);
  final String label;
}

/// Marks where the member's unread check-ins end and already-seen ones begin.
class _CaughtUpItem extends _FeedItem {}

/// Non-blocking notice at the top of the combined feed when some groups couldn't be
/// reached (their posts are simply missing until they come back).
class _UnreachableItem extends _FeedItem {
  _UnreachableItem(this.names);
  final List<String> names;
}

class _GapItem extends _FeedItem {}

class _PostItem extends _FeedItem {
  _PostItem(this.post);
  final Post post;
}

String _dateLabel(DateTime dt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return '$diff days ago';
  return '${dt.month}/${dt.day}/${dt.year}';
}

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

/// What the People filter knows about one (merged) person: the stable key, the freshest
/// display name, a profile photo (media ids are per-server, so the photo carries its
/// group), the ids of the groups they belong to (so the sheet can scope People to the
/// pending group selection), and those groups' colors.
typedef _FilterPerson = ({
  String key,
  String name,
  int? mediaId,
  String? mediaGroupId,
  Set<String> groups,
  List<Color> dots,
});

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _scrollCtrl = ScrollController();
  bool _searchHidden = false;
  double _lastScrollTop = 0;

  // Filter state.
  List<Post> _allPosts = [];
  final Set<String> _people = {}; // selected person keys (PersonDirectory.keyFor)
  bool _includeTagged = true; // also match posts the selected people are tagged in
  _DateFilter? _dateFilter;
  Set<String> _locations = {}; // server-side place filter (mirrors feedLocationProvider)

  // The phone-based cross-group identity join, refreshed from each group's member list
  // when the filter opens. Empty until then - with no selected people it is never
  // consulted, and selections are always made after it loads.
  PersonDirectory _directory = const PersonDirectory.empty();

  // Person key -> a profile photo from the member lists (for people who only appear as
  // tags, or whose posts carry no photo).
  Map<String, ({int? mediaId, String groupId})> _photoByKey = const {};

  // Per-group "newest check-in you'd already seen", loaded once when the screen opens and
  // then held fixed for the whole visit. Holding it fixed is the point: the marker on disk
  // advances as soon as posts are shown, but the caught-up line must stay put under the
  // member rather than sliding away while they read.
  Map<String, DateTime> _seenAt = const {};
  bool _seenLoaded = false;

  // Pagination: posts loaded past the provider's first page, plus loading flags. Reset
  // whenever a fresh first page arrives (pull-to-refresh, compose, location change).
  final List<Post> _morePosts = [];
  bool _loadingMore = false;
  bool _reachedEnd = false;
  // Which shown groups have exhausted their own pages, so a merged ("All") view stops
  // asking a group for more once it says there's nothing further back, while the others
  // keep paging. Reset alongside _morePosts/_reachedEnd.
  final Set<String> _groupsAtEnd = {};

  // Bulk "download all photos matching the current filter" progress.
  bool _downloading = false;
  int _dlDone = 0;
  int _dlTotal = 0;

  bool get _hasFilter => _people.isNotEmpty || _dateFilter != null || _locations.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _loadSeenMarkers();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// Snapshots where the member left off, once per visit. Until it resolves the feed simply
  /// draws no caught-up line, rather than flashing one in the wrong place.
  Future<void> _loadSeenMarkers() async {
    final groups = ref.read(multiSessionProvider).signedIn;
    final seen = await loadSeenMarkers([for (final g in groups) g.id]);
    if (!mounted) return;
    setState(() {
      _seenAt = seen;
      _seenLoaded = true;
    });
  }

  /// Advances the on-disk markers to the newest post on show, so the next visit measures
  /// "new" from here. [_seenAt] is deliberately left alone - see its declaration.
  void _recordSeen(List<Post> posts) {
    if (posts.isEmpty) return;
    final newest = <String, DateTime>{};
    for (final p in posts) {
      final gid = p.groupId;
      if (gid == null) continue;
      final at = newest[gid];
      if (at == null || p.createdAt.isAfter(at)) newest[gid] = p.createdAt;
    }
    saveSeenMarkers(newest);
  }

  void _scrollToTop() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(0,
        duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
  }

  // Hide the top bar only when actively scrolling down; show it at the very top or as
  // soon as the user scrolls up. A small delta avoids flicker on tiny movements.
  void _onScroll() {
    final top = _scrollCtrl.offset;
    final delta = top - _lastScrollTop;
    _lastScrollTop = top;
    if (top <= 8) {
      if (_searchHidden) setState(() => _searchHidden = false);
    } else if (delta > 6 && !_searchHidden) {
      setState(() => _searchHidden = true);
    } else if (delta < -6 && _searchHidden) {
      setState(() => _searchHidden = false);
    }
    // Near the bottom → load the next page. Skipped while a preset (Today/This week/This
    // month) is active, since those sit near "now" and the first page covers them. A custom
    // range can reach into the past, so paging stays on to walk back to it.
    final pos = _scrollCtrl.position;
    if (_dateFilter is! _PresetDate && pos.pixels >= pos.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    HapticFeedback.lightImpact();
    ref.invalidate(feedProvider);
    await ref.read(feedProvider.future);
  }

  /// Every (groupId, postId) pair already represented on screen. A cross-post's copies
  /// each count on their own - so a copy fetched again via a different group's page is
  /// recognised as already-known, not re-added as a duplicate card.
  Set<String> _knownKeys(List<Post> posts) {
    final out = <String>{};
    for (final p in posts) {
      if (p.copies.isNotEmpty) {
        for (final c in p.copies) {
          out.add('${c.groupId}:${c.postId}');
        }
      } else if (p.groupId != null) {
        out.add('${p.groupId}:${p.id}');
      }
    }
    return out;
  }

  /// The (time, id) cursor to resume paging each shown group from: the oldest loaded post
  /// that came from it (a cross-post's copies each count toward their own group's cursor).
  /// [posts] is newest-first, so later writes below overwrite with older ones, leaving
  /// each group's *oldest* seen post once the loop finishes.
  Map<String, (DateTime, int)> _cursorsByGroup(List<Post> posts) {
    final out = <String, (DateTime, int)>{};
    for (final p in posts) {
      if (p.copies.isNotEmpty) {
        for (final c in p.copies) {
          out[c.groupId] = (p.createdAt, c.postId);
        }
      } else if (p.groupId != null) {
        out[p.groupId!] = (p.createdAt, p.id);
      }
    }
    return out;
  }

  /// Fetches the next page for every shown group at once, each from its own (time, id)
  /// cursor, and merges the results - so infinite scroll works the same whether one group
  /// is shown or several ("All"). Cross-posts are collapsed within each freshly-fetched
  /// batch; one whose siblings straddle two groups' pages fetched in different calls to
  /// this method (i.e. it sits at a different page depth in each group) can show as two
  /// cards rather than one - a rare edge case, accepted the same way the single-group
  /// version always accepted "no cross-group cursor" as a simplification.
  Future<void> _loadMore() async {
    if (_loadingMore || _reachedEnd || _allPosts.isEmpty) return;
    final groups = ref.read(multiSessionProvider).shownGroups;
    if (groups.isEmpty) return;
    final cursors = _cursorsByGroup(_allPosts);
    final pending = [
      for (final g in groups)
        if (!_groupsAtEnd.contains(g.id) && cursors[g.id] != null) g
    ];
    if (pending.isEmpty) {
      // Every shown group either has no posts to page from, or already said so.
      setState(() => _reachedEnd = true);
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final results = await Future.wait([
        for (final g in pending)
          ref
              .read(apiForGroupProvider(g.id))
              .feed(locations: _locations, before: cursors[g.id]!.$1, beforeId: cursors[g.id]!.$2)
              .then<List<Post>?>((posts) => [for (final p in posts) p.withGroup(g.id)])
              .catchError((_) => null), // unreachable this round; retried next scroll
      ]);
      if (!mounted) return;
      setState(() {
        final known = _knownKeys(_allPosts);
        final batch = <Post>[];
        for (var i = 0; i < pending.length; i++) {
          final page = results[i];
          if (page == null) continue;
          if (page.isEmpty) {
            _groupsAtEnd.add(pending[i].id);
          } else {
            batch.addAll(page);
          }
        }
        final fresh = collapseCrossPosts(batch).where((p) {
          final keys = p.copies.isNotEmpty
              ? [for (final c in p.copies) '${c.groupId}:${c.postId}']
              : ['${p.groupId}:${p.id}'];
          // .map(...).toList() forces every key to be recorded, even once one is found
          // new - .any's short-circuit would otherwise skip registering the rest.
          return keys.map(known.add).toList().contains(true);
        });
        _morePosts.addAll(fresh);
        if (groups.every((g) => _groupsAtEnd.contains(g.id))) _reachedEnd = true;
      });
    } catch (_) {
      // Leave _reachedEnd false so a later scroll retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openSearch() {
    final session = ref.read(multiSessionProvider);
    final account = session.soleShown;
    if (account == null) {
      _allViewHint('Search works within one group - pick a single group in Filters first.');
      return;
    }
    showSearch<void>(
      context: context,
      delegate: GlobalSearchDelegate(ref.read(apiForGroupProvider(account.id)), account.id),
    );
  }

  /// Search is per-server; in the merged view it'd silently cover only one group, so
  /// be honest and ask for a single group instead.
  void _allViewHint(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // --- filtering ---

  List<Post> _applyFilter(List<Post> posts) {
    return posts
        .where((p) =>
            _people.isEmpty ||
            _people.contains(_directory.keyFor(p.groupId, p.authorId)) ||
            (_includeTagged &&
                p.people.any((t) => _people.contains(_directory.keyFor(p.groupId, t.id)))))
        .where((p) => _dateFilter?.matches(p.createdAt) ?? true)
        .toList();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Gathers every post matching the active filter for a bulk download. In single-group
  /// view it pages the feed to the end (bounded, and stopping once a date filter's window
  /// is passed) so the download isn't limited to what's been scrolled; the merged view has
  /// no cross-group cursor yet, so it uses the loaded posts.
  Future<List<Post>> _collectFilteredForDownload() async {
    final all = [..._allPosts];
    final account = ref.read(multiSessionProvider).soleShown;
    if (account != null && !_reachedEnd && all.isNotEmpty) {
      final api = ref.read(apiForGroupProvider(account.id));
      var cursor = all.last;
      for (var page = 0; page < 40; page++) {
        // Posts are newest-first, so once the cursor is older than the date window, so is
        // everything older - stop paging.
        if (_dateFilter?.isPastWindow(cursor.createdAt) ?? false) break;
        final more = [
          for (final p in await api.feed(
            locations: _locations,
            before: cursor.createdAt,
            beforeId: cursor.id,
          ))
            p.withGroup(account.id)
        ];
        if (more.isEmpty) break;
        final known = all.map((p) => p.id).toSet();
        final lenBefore = all.length;
        all.addAll(more.where((p) => known.add(p.id)));
        // A page that added nothing new means we've caught up - stop rather than re-fetch
        // the same cursor.
        if (all.length == lenBefore) break;
        cursor = all.last;
      }
    }
    return _applyFilter(all);
  }

  /// After a custom range is chosen, pages the feed (bounded) until the loaded posts reach
  /// back past the range's start, so a range in the past isn't an empty dead-end. Presets
  /// sit near "now" and are covered by the first page, so they don't need this. Merged view
  /// has no cross-group cursor yet, so it's a no-op there.
  Future<void> _ensureRangeLoaded(_RangeDate range) async {
    final account = ref.read(multiSessionProvider).soleShown;
    if (account == null || _allPosts.isEmpty || _reachedEnd) return;
    var cursor = _allPosts.last;
    if (range.isPastWindow(cursor.createdAt)) return; // already loaded past the range
    final api = ref.read(apiForGroupProvider(account.id));
    final known = _allPosts.map((p) => p.id).toSet();
    if (mounted) setState(() => _loadingMore = true);
    try {
      for (var page = 0; page < 40; page++) {
        if (range.isPastWindow(cursor.createdAt)) break;
        final more = [
          for (final p in await api.feed(
            locations: _locations,
            before: cursor.createdAt,
            beforeId: cursor.id,
          ))
            p.withGroup(account.id)
        ];
        if (more.isEmpty) {
          if (mounted) setState(() => _reachedEnd = true);
          break;
        }
        final fresh = more.where((p) => known.add(p.id)).toList();
        if (fresh.isEmpty) break;
        if (!mounted) return;
        setState(() => _morePosts.addAll(fresh));
        cursor = fresh.last;
      }
    } catch (_) {
      // Leave it; the user can pull to refresh or scroll to keep loading.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Bulk download entry point: gathers the filtered photos, confirms the count and what's
  /// being saved, then writes them to the gallery. Collecting up front means the dialog can
  /// state an exact count, and the same list is reused for the save (no double paging).
  Future<void> _confirmAndDownload() async {
    setState(() {
      _downloading = true;
      _dlDone = 0;
      _dlTotal = 0;
    });
    List<({String? groupId, int mediaId})> items;
    try {
      final posts = await _collectFilteredForDownload();
      items = [
        for (final p in posts)
          for (final mediaId in p.images) (groupId: p.groupId, mediaId: mediaId)
      ];
    } catch (_) {
      if (mounted) setState(() => _downloading = false);
      _snack("Couldn't prepare the download - check your connection and try again.");
      return;
    }
    if (!mounted) return;
    // Collection is done - while the dialog waits for the user, nothing is "working".
    setState(() => _downloading = false);
    if (items.isEmpty) {
      _snack('No photos match this filter.');
      return;
    }
    if (await _showDownloadConfirm(items.length) != true) return;
    await _saveItems(items);
  }

  /// Writes the gathered photos to the device gallery, reporting progress and the outcome.
  Future<void> _saveItems(List<({String? groupId, int mediaId})> items) async {
    if (!mounted) return;
    setState(() {
      _downloading = true;
      _dlDone = 0;
      _dlTotal = items.length;
    });
    HapticFeedback.mediumImpact();
    var saved = 0;
    var failed = 0;
    try {
      for (final it in items) {
        try {
          final bytes = await ref.read(contentApiProvider(it.groupId)).downloadMedia(it.mediaId);
          await Gal.putImageBytes(bytes);
          saved++;
        } on GalException {
          rethrow; // permission denied - abort the whole run
        } catch (_) {
          failed++;
        }
        if (mounted) setState(() => _dlDone++);
      }
      _snack(failed == 0
          ? 'Saved $saved ${saved == 1 ? 'photo' : 'photos'} to your photos'
          : 'Saved $saved of ${items.length} - $failed could not be saved');
    } on GalException {
      _snack('Allow photo access to save these.');
    } catch (_) {
      _snack("Couldn't download - check your connection and try again.");
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// A plain-language description of the active filter, e.g. "from Jul 1 to Jul 13, with
  /// Alice & Bob, in Paris", for the download confirmation. Empty when nothing is set.
  String _filterSummary() {
    final parts = <String>[];
    final d = _dateFilter;
    if (d is _RangeDate) {
      final f = DateFormat.MMMd();
      parts.add('from ${f.format(d.start)} to ${f.format(d.end)}');
    } else if (d is _PresetDate) {
      parts.add('from ${d.preset.toLowerCase()}');
    }
    if (_people.isNotEmpty) {
      final names = {for (final a in _authors()) a.key: a.name};
      parts.add('with ${_joinNames([for (final k in _people) names[k] ?? 'someone'])}');
    }
    if (_locations.isNotEmpty) parts.add('in ${_joinNames(_locations.toList())}');
    return parts.join(', ');
  }

  String _joinNames(List<String> names) {
    if (names.length <= 1) return names.isEmpty ? '' : names.first;
    if (names.length == 2) return '${names[0]} & ${names[1]}';
    return '${names.sublist(0, names.length - 1).join(', ')} & ${names.last}';
  }

  Future<bool?> _showDownloadConfirm(int count) {
    final photos = '$count ${count == 1 ? 'photo' : 'photos'}';
    final summary = _filterSummary();
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bgSurface,
        title: Text('Download $photos?',
            style: const TextStyle(color: _fgPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
        content: Text(
          summary.isEmpty
              ? 'Save $photos to your device.'
              : 'Save $photos $summary to your device.',
          style: const TextStyle(color: _fgSecondary, fontSize: 14.5, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _fgSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: context.accent, foregroundColor: context.onAccent),
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  /// People present in the loaded feed - authors plus anyone tagged in a post - for the
  /// filter sheet, so you can filter by someone who only appears in photos. Keys come
  /// from the directory, so the same human in several groups collapses to one entry
  /// (freshest name/photo wins - the feed is newest-first); their group memberships
  /// render as color dots when more than one group is signed in.
  List<_FilterPerson> _authors() {
    final session = ref.read(multiSessionProvider);
    final multi = session.signedIn.length > 1;
    List<Color> dotsFor(String key) {
      if (!multi) return const [];
      return [
        for (final gid in _directory.groupsFor(key))
          if (session.byId(gid) != null) session.byId(gid)!.displayColor
      ];
    }

    final seen = <String>{};
    final out = <_FilterPerson>[];
    void add(String key, String name, int? mediaId, String? mediaGroupId) {
      if (!seen.add(key)) return;
      // Posts may not carry a photo (tags never do); the member lists usually can.
      final fallback = _photoByKey[key];
      out.add((
        key: key,
        name: name,
        mediaId: mediaId ?? fallback?.mediaId,
        mediaGroupId: mediaId != null ? mediaGroupId : fallback?.groupId,
        groups: _directory.groupsFor(key),
        dots: dotsFor(key),
      ));
    }

    for (final p in _allPosts) {
      add(_directory.keyFor(p.groupId, p.authorId), p.authorName, p.authorPhotoId, p.groupId);
      for (final person in p.people) {
        add(_directory.keyFor(p.groupId, person.id), person.name, null, null);
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Refreshes the cross-group identity join from each signed-in group's member list.
  /// Unreachable groups contribute nothing - their people stay per-group.
  Future<void> _loadDirectory() async {
    final session = ref.read(multiSessionProvider);
    final groups = session.signedIn;
    final lists = await Future.wait([
      for (final g in groups)
        ref.read(groupMembersProvider(g.id).future).catchError((_) => <User>[]),
    ]);
    final byGroup = <String, List<User>>{};
    for (var i = 0; i < groups.length; i++) {
      if (lists[i].isNotEmpty) byGroup[groups[i].id] = lists[i];
    }
    final directory = PersonDirectory.fromMemberLists(byGroup);
    final photos = <String, ({int? mediaId, String groupId})>{};
    byGroup.forEach((groupId, members) {
      for (final u in members) {
        final key = directory.keyFor(groupId, u.id);
        // First photo wins; a later group only fills a still-missing one.
        if (photos[key]?.mediaId == null && u.profileMediaId != null) {
          photos[key] = (mediaId: u.profileMediaId, groupId: groupId);
        }
      }
    });
    if (!mounted) return;
    setState(() {
      _directory = directory;
      _photoByKey = photos;
    });
  }

  Future<void> _openFilter() async {
    final session = ref.read(multiSessionProvider);
    // The identity join first, so the sheet opens with people already merged.
    await _loadDirectory();
    // Places are per-server: merge every shown group's list, summing counts for the same
    // label. A group that can't be reached simply contributes nothing.
    final counts = <String, int>{};
    for (final g in session.shownGroups) {
      try {
        final locs = await ref.read(locationsProvider(g.id).future);
        for (final l in locs) {
          counts[l.location] = (counts[l.location] ?? 0) + l.count;
        }
      } catch (_) {}
    }
    final locs = [for (final e in counts.entries) (location: e.key, count: e.value)]
      ..sort((a, b) => b.count.compareTo(a.count));
    if (!mounted) return;
    final result = await showModalBottomSheet<
        ({
          Set<String> hidden,
          Set<String> people,
          bool includeTagged,
          _DateFilter? date,
          Set<String> locations
        })>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _FilterSheet(
        groups: session.groups,
        hiddenGroupIds: session.hiddenGroupIds,
        // Session expired there - run the (additive) login flow again. (Adding a group
        // lives in Settings > Edit groups, not here.)
        onRelogin: (g) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AuthScreen(initialServer: g.baseUrl)),
        ),
        authors: _authors(),
        selectedPeople: _people,
        includeTagged: _includeTagged,
        dateFilter: _dateFilter,
        locations: locs,
        selectedLocations: _locations,
      ),
    );
    if (result == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _people
        ..clear()
        ..addAll(result.people);
      _includeTagged = result.includeTagged;
      _dateFilter = result.date;
      _locations = result.locations;
    });
    // Group visibility and location both refetch the feed via their providers.
    ref.read(multiSessionProvider.notifier).setHiddenGroups(result.hidden);
    ref.read(feedLocationProvider.notifier).state = _locations;
    // A past custom range can sit beyond the first page - walk back to it so the feed
    // isn't an empty dead-end.
    if (result.date is _RangeDate) _ensureRangeLoaded(result.date as _RangeDate);
  }

  /// Whether [p] was posted after the member last saw this group's feed.
  bool _isUnread(Post p) {
    final seen = _seenAt[p.groupId];
    // No marker = never visited this group's feed, so nothing is "new" to catch up on.
    return seen != null && p.createdAt.isAfter(seen);
  }

  /// Index of the first already-seen post, or null when every post is new. Posts arrive
  /// newest-first, so this is exactly where the caught-up line belongs.
  int? _caughtUpAt(List<Post> posts) {
    if (!_seenLoaded || _hasFilter) return null; // a filtered feed isn't a reading position
    for (var i = 0; i < posts.length; i++) {
      if (!_isUnread(posts[i])) return i;
    }
    return null;
  }

  List<_FeedItem> _buildItems(List<Post> posts, List<String> unreachable) {
    final items = <_FeedItem>[];
    if (unreachable.isNotEmpty) items.add(_UnreachableItem(unreachable));
    // Only worth drawing when there's unread above it AND seen posts below it - a line at
    // the very top or with nothing under it says nothing.
    final caughtUpAt = _caughtUpAt(posts);
    String? lastLabel;
    for (var i = 0; i < posts.length; i++) {
      if (i == caughtUpAt && i > 0) {
        items.add(_CaughtUpItem());
        lastLabel = null; // restart date grouping below the line so the next date re-labels
      }
      final post = posts[i];
      final label = _dateLabel(post.createdAt.toLocal());
      if (label != lastLabel) {
        items.add(_DividerItem(label));
        lastLabel = label;
      } else {
        items.add(_GapItem());
      }
      items.add(_PostItem(post));
    }
    return items;
  }

  Widget _buildItem(_FeedItem item, {required bool allView}) {
    return switch (item) {
      _DividerItem(:final label) => _DateDivider(label: label),
      _CaughtUpItem() => const _CaughtUpDivider(),
      _GapItem() => const _GapConnector(),
      _UnreachableItem(:final names) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _bgSurface,
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_off_outlined, size: 16, color: _fgMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Couldn't reach ${names.join(', ')} - showing the rest.",
                    style: const TextStyle(color: _fgSecondary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      _PostItem(:final post) => PostCard(
          key: ValueKey('${post.groupId}-${post.id}'),
          post: post,
          // Merged view only: tint the card by its origin group so groups are told apart.
          groupColor:
              allView ? ref.read(multiSessionProvider).byId(post.groupId)?.displayColor : null,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    // A fresh first page (refresh / compose / location / group change) invalidates any
    // pages we scrolled in, so drop them and allow loading again from the new base.
    ref.listen(feedProvider, (prev, next) {
      if (next is AsyncData<FeedResult>) {
        _morePosts.clear();
        _reachedEnd = false;
        _groupsAtEnd.clear();
        // These posts are now on screen, so the member is caught up to them from the next
        // visit's point of view. The in-memory _seenAt is untouched, so the line they're
        // reading against stays where it is.
        _recordSeen(next.value.posts);
      }
    });
    // Home-tab re-tap (from the bottom nav) scrolls the feed back to the top.
    ref.listen(feedScrollToTopProvider, (_, __) => _scrollToTop());
    final session = ref.watch(multiSessionProvider);
    final allView = session.isAllView;
    return Scaffold(
      backgroundColor: _bgMain,
      body: Stack(
        children: [
          SafeArea(
            child: Stack(
              children: [
                PrimaryScrollController(
                  controller: _scrollCtrl,
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    color: context.accent,
                    backgroundColor: _bgSurface,
                    child: ref.watch(feedProvider).when(
                          loading: () => const FeedSkeleton(),
                          error: (e, _) => ListView(primary: false, children: [
                            const SizedBox(height: 120),
                            Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.cloud_off_outlined, size: 42, color: _fgMuted),
                                  const SizedBox(height: 12),
                                  const Text('Could not load the feed.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: _fgSecondary, fontSize: 15)),
                                  const SizedBox(height: 10),
                                  TextButton(onPressed: _refresh, child: const Text('Try again')),
                                ],
                              ),
                            ),
                          ]),
                          data: (result) {
                            _allPosts = [...result.posts, ..._morePosts];
                            final posts = _applyFilter(_allPosts);
                            if (_allPosts.isEmpty) {
                              final s = ref.read(multiSessionProvider);
                              if (s.nothingShown) {
                                // Every group is toggled off - say so instead of "no check-ins".
                                return _emptyState(
                                  icon: Icons.public_off,
                                  title: 'No groups shown',
                                  subtitle: 'Choose which groups appear in Filters.',
                                );
                              }
                              final shown = s.shownGroups;
                              final where = shown.length > 1
                                  ? ' in ${[for (final g in shown) g.displayName].join(', ')}'
                                  : '';
                              return _emptyState(
                                icon: Icons.photo_camera_outlined,
                                title: 'No check-ins yet$where',
                                subtitle: 'Tap + to share an update.',
                              );
                            }
                            final items = _buildItems(
                                posts, [for (final g in result.unreachable) g.displayName]);
                            // Trailing spinner row while the next page loads.
                            final showSpinner = _loadingMore && posts.isNotEmpty;
                            return ListView.builder(
                              // Primary so the pagination controller (_scrollCtrl) attaches
                              // here; that also drives _scrollToTop() for the Home-tap and
                              // the status-bar tap-strip.
                              primary: true,
                              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: EdgeInsets.only(top: _hasFilter ? 116 : 72, bottom: 24),
                              itemCount: posts.isEmpty ? 1 : items.length + (showSpinner ? 1 : 0),
                              itemBuilder: (_, i) {
                                if (posts.isEmpty) {
                                  return const Padding(
                                    padding: EdgeInsets.only(top: 60),
                                    child: Center(
                                      child: Text('No check-ins match your filters.',
                                          style: TextStyle(color: _fgMuted)),
                                    ),
                                  );
                                }
                                if (i >= items.length) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 20),
                                    child: Center(
                                        child: CircularProgressIndicator(color: context.accent)),
                                  );
                                }
                                return _buildItem(items[i], allView: allView);
                              },
                            );
                          },
                        ),
                  ),
                ),
                // Floating search bar + active filter chips - slide away on scroll down.
                AnimatedSlide(
                  offset: _searchHidden ? const Offset(0, -2) : Offset.zero,
                  duration: const Duration(milliseconds: 280),
                  curve: const Cubic(0.2, 0.8, 0.2, 1.0),
                  child: AnimatedOpacity(
                    opacity: _searchHidden ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: _searchHidden,
                      child: Column(
                        children: [
                          _SearchBar(
                            onSearch: _openSearch,
                            onFilter: _openFilter,
                            filterActive: _hasFilter,
                            downloading: _downloading,
                            downloadProgress: _dlTotal > 0 ? _dlDone / _dlTotal : null,
                            onDownload: _confirmAndDownload,
                          ),
                          if (_hasFilter) _activeChips(),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Invisible strip over the status-bar inset. Tapping it jumps back to the top of
          // the feed. iOS's native status-bar tap-to-top is unreliable here because the
          // profile tab stays mounted in the IndexedStack (a second primary scroll view),
          // so we handle the gesture ourselves.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).padding.top,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _scrollToTop,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState({required IconData icon, required String title, required String subtitle}) {
    return ListView(primary: false, children: [
      const SizedBox(height: 150),
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: _fgMuted),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: _fgSecondary, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(color: _fgMuted, fontSize: 13)),
          ],
        ),
      ),
    ]);
  }

  Widget _activeChips() {
    final names = {for (final a in _authors()) a.key: a.name};
    final chips = <Widget>[
      for (final key in _people)
        _filterChip(names[key] ?? 'Someone', () => setState(() => _people.remove(key))),
      if (_dateFilter != null)
        _filterChip(_dateFilter!.label, () => setState(() => _dateFilter = null)),
      for (final loc in _locations)
        _filterChip(loc, () {
          setState(() => _locations.remove(loc));
          ref.read(feedLocationProvider.notifier).state = _locations;
        }),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 8, runSpacing: 8, children: chips),
      ),
    );
  }

  /// A removable chip for one active filter. These float over the scrolling feed, so the
  /// accent tint is composited onto the app background rather than left at 16% alpha - a
  /// translucent fill is unreadable once a photo scrolls under it - and it carries the same
  /// lift as the search bar above it.
  Widget _filterChip(String label, VoidCallback onRemove) {
    return Semantics(
      button: true,
      label: 'Remove $label filter',
      child: GestureDetector(
        onTap: onRemove,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.fromLTRB(11, 5, 9, 5),
          decoration: BoxDecoration(
            color: Color.alphaBlend(context.accentLight, _bgMain),
            border: Border.all(color: context.accent),
            borderRadius: BorderRadius.circular(9999),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withAlpha(90), blurRadius: 14, offset: const Offset(0, 5)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style:
                      TextStyle(color: context.accent, fontWeight: FontWeight.w600, fontSize: 12)),
              const SizedBox(width: 5),
              Icon(Icons.close, size: 15, color: context.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.onSearch,
    required this.onFilter,
    required this.filterActive,
    required this.downloading,
    required this.downloadProgress,
    required this.onDownload,
  });

  final VoidCallback onSearch;
  final VoidCallback onFilter;
  final bool filterActive;

  /// Bulk-download state. The compact button appears (left of Filters) only when a filter
  /// is active, since that's the only time "download everything matching" is meaningful.
  final bool downloading;
  final double? downloadProgress; // 0..1 while saving, null while preparing
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: _pill(context),
    );
  }

  Widget _pill(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bgSurface,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(76), blurRadius: 26, offset: const Offset(0, 10)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(13, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: 'Search check-ins and people',
              child: GestureDetector(
                onTap: onSearch,
                behavior: HitTestBehavior.opaque,
                // Icon + hint are one tap target (the magnifier used to be dead).
                child: const Row(
                  children: [
                    Icon(Icons.search, size: 19, color: _fgMuted),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text('Search check-ins & people',
                          style: TextStyle(color: _fgMuted, fontSize: 14)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (filterActive) _downloadButton(context),
          Semantics(
            button: true,
            label: 'Filters',
            child: GestureDetector(
              onTap: onFilter,
              behavior: HitTestBehavior.opaque,
              // 44px hit area around the 30px visual chip.
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: filterActive ? context.accent : _bgSurfaceHover,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.filter_list,
                        size: 19, color: filterActive ? context.onAccent : _fgSecondary),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact "save every photo matching this filter" button, sized to match the Filters
  /// chip. Shows a progress ring while working (determinate once the count is known).
  Widget _downloadButton(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Download photos matching this filter',
      child: GestureDetector(
        onTap: downloading ? null : onDownload,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: _bgSurfaceHover,
                borderRadius: BorderRadius.circular(8),
              ),
              child: downloading
                  ? Padding(
                      padding: const EdgeInsets.all(7),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, value: downloadProgress, color: context.accent),
                    )
                  : const Icon(Icons.download_rounded, size: 19, color: _fgSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet to filter the feed: which groups show, plus person/date/place. Group
/// visibility applies with the rest on "Show results"; every group may be toggled off
/// (the feed then shows a "no groups shown" state). No group chip appears under the
/// search bar for any selection.
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.groups,
    required this.hiddenGroupIds,
    required this.onRelogin,
    required this.authors,
    required this.selectedPeople,
    required this.includeTagged,
    required this.dateFilter,
    required this.locations,
    required this.selectedLocations,
  });

  /// Every connected group (signed-out ones offer re-login).
  final List<ServerAccount> groups;
  final Set<String> hiddenGroupIds;
  final void Function(ServerAccount) onRelogin;

  final List<_FilterPerson> authors;
  final Set<String> selectedPeople;
  final bool includeTagged;
  final _DateFilter? dateFilter;
  final List<({String location, int count})> locations;
  final Set<String> selectedLocations;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final Set<String> _hidden = {...widget.hiddenGroupIds};
  late final Set<String> _people = {...widget.selectedPeople};
  late bool _includeTagged = widget.includeTagged;
  late _DateFilter? _date = widget.dateFilter;
  late final Set<String> _locations = {...widget.selectedLocations};
  String _personQuery = '';

  List<ServerAccount> get _signedIn => [
        for (final g in widget.groups)
          if (g.isSignedIn) g
      ];

  /// People scoped to the pending group selection: only members of at least one
  /// still-selected group. Unknown memberships (empty set) stay visible - scoping is a
  /// convenience, never a trap.
  List<_FilterPerson> get _visiblePeople => [
        for (final a in widget.authors)
          if (a.groups.isEmpty || a.groups.any((g) => !_hidden.contains(g))) a
      ];

  void _apply() {
    // Drop selected people we KNOW are scoped out by the group selection, so a hidden
    // group can't keep filtering the feed through an invisible person chip.
    final byKey = {for (final a in widget.authors) a.key: a};
    _people.removeWhere((k) {
      final a = byKey[k];
      return a != null && a.groups.isNotEmpty && a.groups.every(_hidden.contains);
    });
    Navigator.of(context).pop((
      hidden: _hidden,
      people: _people,
      includeTagged: _includeTagged,
      date: _date,
      locations: _locations,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Reacts live to the pending group pills: deselect a group and its people vanish.
    final people = _visiblePeople;
    // Capped well below full screen height so there's always clear room above for the
    // status bar/notch - matching showDateRangeSheet's own sheet, which uses the same
    // fixed-cap-instead-of-SafeArea-top approach. Without a cap, a long filter list (many
    // groups/people) could grow the sheet tall enough to slide its header up underneath
    // the status bar.
    final maxHeight = MediaQuery.of(context).size.height * 0.82;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration:
                      BoxDecoration(color: _border, borderRadius: BorderRadius.circular(9999)),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Filter',
                      style:
                          TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
                  Semantics(
                    button: true,
                    label: 'Close',
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration:
                                const BoxDecoration(color: _bgSurfaceHover, shape: BoxShape.circle),
                            child: const Icon(Icons.close, size: 18, color: _fgSecondary),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // Only this middle section scrolls - the header above and Clear/Show results
              // below stay pinned, so a long filter list never pushes the buttons off
              // screen or behind a scroll.
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _filterSections(context, people),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setState(() {
                        // Clearing everything includes the group scope: back to All.
                        _hidden.clear();
                        _people.clear();
                        _date = null;
                        _locations.clear();
                      }),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _fgSecondary,
                        side: const BorderSide(color: _border),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Clear'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _apply,
                      style: FilledButton.styleFrom(
                        backgroundColor: context.accent,
                        foregroundColor: context.onAccent,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child:
                          const Text('Show results', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Everything that scrolls in the middle of the sheet: groups, people, date, place.
  Widget _filterSections(BuildContext context, List<_FilterPerson> people) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // With a single connected group there is nothing to scope, so the whole GROUPS
        // section disappears - a one-group member never sees multi-group machinery.
        if (widget.groups.length > 1) ...[
          const Text('GROUPS',
              style: TextStyle(
                  color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 0.4)),
          const SizedBox(height: 11),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_signedIn.length > 1)
                _groupPill(
                  label: 'All',
                  on: _hidden.isEmpty,
                  // A real toggle: everything on, or - when already all on - everything
                  // off (the feed then shows its "no groups shown" state).
                  onTap: () => setState(() {
                    if (_hidden.isEmpty) {
                      _hidden.addAll([for (final g in _signedIn) g.id]);
                    } else {
                      _hidden.clear();
                    }
                  }),
                ),
              for (final g in widget.groups)
                if (g.isSignedIn)
                  _groupPill(
                    label: g.displayName,
                    dot: g.displayColor,
                    on: !_hidden.contains(g.id),
                    onTap: () => setState(() {
                      if (!_hidden.remove(g.id)) _hidden.add(g.id);
                    }),
                  )
                else
                  _groupPill(
                    label: g.displayName,
                    locked: true,
                    on: false,
                    onTap: () {
                      // Session expired there - run the (additive) login flow again.
                      Navigator.of(context).pop();
                      widget.onRelogin(g);
                    },
                  ),
            ],
          ),
          const SizedBox(height: 22),
        ],
        // The section stays put as long as anyone exists at all - scoping it empty
        // swaps in a hint instead of collapsing the whole block, and the size change
        // animates so the sheet never jumps.
        if (widget.authors.isNotEmpty) ...[
          const Text('PEOPLE',
              style: TextStyle(
                  color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 0.4)),
          const SizedBox(height: 10),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: people.isEmpty
                ? const SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: EdgeInsets.only(top: 2, bottom: 4),
                      child: Text('Select a group to filter by people.',
                          style: TextStyle(color: _fgMuted, fontSize: 13)),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (people.length > 5) ...[
                        TextField(
                          onChanged: (v) => setState(() => _personQuery = v.trim().toLowerCase()),
                          style: const TextStyle(color: _fgPrimary, fontSize: 14),
                          cursorColor: context.accent,
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 18, color: _fgMuted),
                            hintText: 'Search people',
                            hintStyle: const TextStyle(color: _fgMuted, fontSize: 14),
                            filled: true,
                            fillColor: _bgMain,
                            contentPadding: const EdgeInsets.symmetric(vertical: 10),
                            enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: _border)),
                            focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: context.accent)),
                          ),
                        ),
                        const SizedBox(height: 11),
                      ],
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final a in people.where((a) =>
                              _personQuery.isEmpty || a.name.toLowerCase().contains(_personQuery)))
                            _personChip(a),
                        ],
                      ),
                      if (_people.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => _includeTagged = !_includeTagged),
                            child: Row(
                              children: [
                                const Expanded(
                                  child: Text("Also show posts they're tagged in",
                                      style: TextStyle(color: _fgSecondary, fontSize: 13.5)),
                                ),
                                Switch.adaptive(
                                  value: _includeTagged,
                                  onChanged: (v) => setState(() => _includeTagged = v),
                                  activeThumbColor: context.accent,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 22),
        ],
        const Text('DATE',
            style: TextStyle(
                color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 0.4)),
        const SizedBox(height: 11),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final d in _datePresets) _datePill(d),
            _customRangePill(context),
          ],
        ),
        if (widget.locations.isNotEmpty) ...[
          const SizedBox(height: 22),
          const Text('PLACE',
              style: TextStyle(
                  color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 0.4)),
          const SizedBox(height: 11),
          _placeField(context),
        ],
      ],
    );
  }

  /// One group toggle pill: a checkmark when shown, the group's identity dot, a lock for
  /// signed-out groups (tap = re-login).
  Widget _groupPill({
    required String label,
    required bool on,
    required VoidCallback onTap,
    Color? dot,
    bool locked = false,
  }) {
    return Semantics(
      button: true,
      selected: on,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: on ? context.accent : Colors.transparent,
            border: Border.all(color: on ? context.accent : _border),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (locked) ...[
                const Icon(Icons.lock_outline, size: 13, color: _fgMuted),
                const SizedBox(width: 5),
              ] else if (dot != null) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              if (on) ...[
                Icon(Icons.check, size: 14, color: context.onAccent),
                const SizedBox(width: 4),
              ],
              Text(label,
                  style: TextStyle(
                      color: on ? context.onAccent : _fgSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _personChip(_FilterPerson a) {
    final on = _people.contains(a.key);
    return Semantics(
      button: true,
      selected: on,
      label: a.name,
      child: GestureDetector(
        onTap: () => setState(() => on ? _people.remove(a.key) : _people.add(a.key)),
        child: Container(
          padding: const EdgeInsets.fromLTRB(5, 5, 13, 5),
          decoration: BoxDecoration(
            color: on ? context.accent : Colors.transparent,
            border: Border.all(color: on ? context.accent : _border),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The real profile photo (media ids are per-server: fetched from the group
              // the photo lives on); falls back to the initial when there is none.
              UserAvatar(
                name: a.name,
                size: 24,
                mediaId: a.mediaId,
                colorSeed: a.key.hashCode,
                groupId: a.mediaGroupId,
              ),
              const SizedBox(width: 7),
              Text(a.name,
                  style: TextStyle(
                      color: on ? context.onAccent : _fgSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              // One dot per group this person belongs to (merged identities only).
              if (a.dots.isNotEmpty) const SizedBox(width: 6),
              for (final c in a.dots)
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(left: 3),
                  decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _datePill(String label) {
    final date = _date;
    final on = date is _PresetDate && date.preset == label;
    return Semantics(
      button: true,
      selected: on,
      label: label,
      child: GestureDetector(
        onTap: () => setState(() => _date = on ? null : _PresetDate(label)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            color: on ? context.accent : Colors.transparent,
            border: Border.all(color: on ? context.accent : _border),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Text(label,
              style: TextStyle(
                  color: on ? context.onAccent : _fgSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ),
      ),
    );
  }

  /// The "Custom range" pill: opens a calendar range picker and, once picked, shows the
  /// chosen span (tap again to adjust). Picking a preset above clears it, and vice versa.
  Widget _customRangePill(BuildContext context) {
    final date = _date;
    final range = date is _RangeDate ? date : null;
    final on = range != null;
    return Semantics(
      button: true,
      selected: on,
      label: on ? 'Custom range, ${range.label}' : 'Custom date range',
      child: GestureDetector(
        onTap: _pickRange,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: on ? context.accent : Colors.transparent,
            border: Border.all(color: on ? context.accent : _border),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_outlined, size: 15, color: on ? context.onAccent : _fgSecondary),
              const SizedBox(width: 6),
              Text(on ? range.label : 'Custom range',
                  style: TextStyle(
                      color: on ? context.onAccent : _fgSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final date = _date;
    final current = date is _RangeDate ? date : null;
    final choice = await showDateRangeSheet(
      context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year, now.month, now.day),
      initial: current == null
          ? null
          : DateTimeRange(
              start: DateTime(current.start.year, current.start.month, current.start.day),
              end: DateTime(current.end.year, current.end.month, current.end.day),
            ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      switch (choice) {
        // Normalize to whole local days: start at midnight, end at the last second.
        case PickRange(:final range):
          _date = _RangeDate(
            DateTime(range.start.year, range.start.month, range.start.day),
            DateTime(range.end.year, range.end.month, range.end.day, 23, 59, 59),
          );
        case ClearRange():
          _date = null;
      }
    });
  }

  /// A compact field standing in for the (potentially long) list of places: shows the
  /// current selection and opens a picker sheet, rather than a Wrap of pills that grows
  /// with the group's place count and pushes the sheet's own Clear/Show results down.
  Widget _placeField(BuildContext context) {
    final on = _locations.isNotEmpty;
    return Semantics(
      button: true,
      label: on ? 'Place filter, $_placeLabel selected' : 'Place filter, none selected',
      child: GestureDetector(
        onTap: _pickPlace,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: on ? context.accent : Colors.transparent,
            border: Border.all(color: on ? context.accent : _border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.place_outlined, size: 16, color: on ? context.onAccent : _fgSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_placeLabel,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: on ? context.onAccent : _fgSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5)),
              ),
              Icon(Icons.expand_more, size: 18, color: on ? context.onAccent : _fgMuted),
            ],
          ),
        ),
      ),
    );
  }

  /// The compact field's label: none selected reads as "All places", one names it
  /// directly, several collapse to a count rather than overflowing the field.
  String get _placeLabel {
    if (_locations.isEmpty) return 'All places';
    if (_locations.length == 1) return _locations.first;
    return '${_locations.length} places';
  }

  /// Opens the multi-select place picker and applies whatever set it returns. A plain
  /// null return (dismissed via the back gesture) means no change.
  Future<void> _pickPlace() async {
    final result = await showModalBottomSheet<_PickPlaces>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _PlacePickerSheet(locations: widget.locations, selected: _locations),
    );
    if (result == null || !mounted) return;
    setState(() {
      _locations
        ..clear()
        ..addAll(result.locations);
    });
  }
}

/// Result of [_pickPlace]'s sheet: the applied set of places (empty means "All places").
class _PickPlaces {
  const _PickPlaces(this.locations);
  final Set<String> locations;
}

/// Bottom sheet listing every place as a checkable row, with a search field once the list
/// is long (mirroring the PEOPLE section's own >5 threshold). Selections stage locally and
/// only take effect on Apply - mirrors _DateRangeSheet's Clear/Apply footer, with "All
/// places" as this picker's Clear.
class _PlacePickerSheet extends StatefulWidget {
  const _PlacePickerSheet({required this.locations, required this.selected});

  final List<({String location, int count})> locations;
  final Set<String> selected;

  @override
  State<_PlacePickerSheet> createState() => _PlacePickerSheetState();
}

class _PlacePickerSheetState extends State<_PlacePickerSheet> {
  late final Set<String> _staged = {...widget.selected};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    // Same fixed-cap approach as the filter sheet itself and showDateRangeSheet, so the
    // header never slides up under the status bar.
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    final filtered = [
      for (final l in widget.locations)
        if (_query.isEmpty || l.location.toLowerCase().contains(_query)) l
    ];
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration:
                      BoxDecoration(color: _border, borderRadius: BorderRadius.circular(9999)),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Place',
                      style:
                          TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
                  if (_staged.isNotEmpty)
                    Text('${_staged.length} selected',
                        style: const TextStyle(
                            color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 13.5)),
                ],
              ),
              if (widget.locations.length > 6) ...[
                const SizedBox(height: 10),
                TextField(
                  autofocus: false,
                  onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                  style: const TextStyle(color: _fgPrimary, fontSize: 14),
                  cursorColor: context.accent,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18, color: _fgMuted),
                    hintText: 'Search places',
                    hintStyle: const TextStyle(color: _fgMuted, fontSize: 14),
                    filled: true,
                    fillColor: _bgMain,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: context.accent)),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Flexible(
                child: filtered.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                            child: Text('No places match.', style: TextStyle(color: _fgMuted))),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (_, i) => _placeRow(filtered[i]),
                      ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(const _PickPlaces({})),
                    style: TextButton.styleFrom(foregroundColor: _fgSecondary),
                    child: const Text('All places'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_PickPlaces(_staged)),
                    style: FilledButton.styleFrom(
                      backgroundColor: context.accent,
                      foregroundColor: context.onAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeRow(({String location, int count}) l) {
    final on = _staged.contains(l.location);
    return Semantics(
      button: true,
      selected: on,
      label: l.location,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() {
          HapticFeedback.selectionClick();
          if (on) {
            _staged.remove(l.location);
          } else {
            _staged.add(l.location);
          }
        }),
        child: Padding(
          // 22 (checkbox) + 11 * 2 lands the row on the 44px minimum tap target.
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: on ? context.accent : Colors.transparent,
                  border: Border.all(color: on ? context.accent : _border, width: 1.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: on ? Icon(Icons.check, size: 15, color: context.onAccent) : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(l.location,
                    style: TextStyle(
                        color: on ? context.accent : _fgPrimary,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 14.5)),
              ),
              const SizedBox(width: 10),
              Text('${l.count}', style: const TextStyle(color: _fgMuted, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

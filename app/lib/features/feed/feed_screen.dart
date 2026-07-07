import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/person_directory.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/user_avatar.dart';
import '../onboarding/auth_screen.dart';
import 'global_search_delegate.dart';
import 'post_card.dart';

// Theme tokens (centralized in theme/tokens.dart).
const _bgMain = kBgMain;
const _bgSurface = kBgSurface;
const _bgSurfaceHover = kBgSurfaceHover;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;

const _datePresets = ['Today', 'This week', 'This month'];

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

sealed class _FeedItem {}

class _DividerItem extends _FeedItem {
  _DividerItem(this.label);
  final String label;
}

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
  String? _datePreset;
  String? _location; // server-side place filter (mirrors feedLocationProvider)

  // The phone-based cross-group identity join, refreshed from each group's member list
  // when the filter opens. Empty until then - with no selected people it is never
  // consulted, and selections are always made after it loads.
  PersonDirectory _directory = const PersonDirectory.empty();

  // Person key -> a profile photo from the member lists (for people who only appear as
  // tags, or whose posts carry no photo).
  Map<String, ({int? mediaId, String groupId})> _photoByKey = const {};

  // Pagination: posts loaded past the provider's first page, plus loading flags. Reset
  // whenever a fresh first page arrives (pull-to-refresh, compose, location change).
  final List<Post> _morePosts = [];
  bool _loadingMore = false;
  bool _reachedEnd = false;

  bool get _hasFilter => _people.isNotEmpty || _datePreset != null || _location != null;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
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
    // Near the bottom → load the next page. Skipped while a date preset is active, since
    // that filter is client-side and self-bounded (avoids loading the whole history).
    final pos = _scrollCtrl.position;
    if (_datePreset == null && pos.pixels >= pos.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    HapticFeedback.lightImpact();
    ref.invalidate(feedProvider);
    await ref.read(feedProvider.future);
  }

  /// Fetch the next page using the oldest loaded post as a composite (time,id) cursor.
  /// Single-group view only — the All view is a first-page merge (cross-group cursor
  /// pagination is a follow-up), so infinite scroll is disabled there.
  Future<void> _loadMore() async {
    if (_loadingMore || _reachedEnd || _allPosts.isEmpty) return;
    final session = ref.read(multiSessionProvider);
    final account = session.soleShown;
    if (account == null) return; // merged view: no cross-group cursor pagination yet
    setState(() => _loadingMore = true);
    final last = _allPosts.last;
    try {
      final page = await ref.read(apiForGroupProvider(account.id)).feed(
            location: _location,
            before: last.createdAt,
            beforeId: last.id,
          );
      final more = [for (final p in page) p.withGroup(account.id)];
      if (!mounted) return;
      setState(() {
        if (more.isEmpty) {
          _reachedEnd = true;
        } else {
          final known = _allPosts.map((p) => p.id).toSet();
          _morePosts.addAll(more.where((p) => known.add(p.id)));
        }
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
      _allViewHint('Search works within one group — pick a single group in Filters first.');
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

  bool _withinPreset(DateTime created) {
    if (_datePreset == null) return true;
    final now = DateTime.now();
    final c = created.toLocal();
    return switch (_datePreset) {
      'Today' => c.year == now.year && c.month == now.month && c.day == now.day,
      'This week' => now.difference(c).inDays < 7,
      'This month' => now.difference(c).inDays < 31,
      _ => true,
    };
  }

  List<Post> _applyFilter(List<Post> posts) {
    return posts
        .where((p) =>
            _people.isEmpty ||
            _people.contains(_directory.keyFor(p.groupId, p.authorId)) ||
            (_includeTagged &&
                p.people.any((t) => _people.contains(_directory.keyFor(p.groupId, t.id)))))
        .where((p) => _withinPreset(p.createdAt))
        .toList();
  }

  /// People present in the loaded feed — authors plus anyone tagged in a post — for the
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
          String? date,
          String? location
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
        // Session expired there — run the (additive) login flow again. (Adding a group
        // lives in Settings > Edit groups, not here.)
        onRelogin: (g) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AuthScreen(initialServer: g.baseUrl)),
        ),
        authors: _authors(),
        selectedPeople: _people,
        includeTagged: _includeTagged,
        datePreset: _datePreset,
        locations: locs,
        selectedLocation: _location,
      ),
    );
    if (result == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _people
        ..clear()
        ..addAll(result.people);
      _includeTagged = result.includeTagged;
      _datePreset = result.date;
      _location = result.location;
    });
    // Group visibility and location both refetch the feed via their providers.
    ref.read(multiSessionProvider.notifier).setHiddenGroups(result.hidden);
    ref.read(feedLocationProvider.notifier).state = _location;
  }

  List<_FeedItem> _buildItems(List<Post> posts, List<String> unreachable) {
    final items = <_FeedItem>[];
    if (unreachable.isNotEmpty) items.add(_UnreachableItem(unreachable));
    String? lastLabel;
    for (final post in posts) {
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
                    "Couldn't reach ${names.join(', ')} — showing the rest.",
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
      }
    });
    final session = ref.watch(multiSessionProvider);
    final allView = session.isAllView;
    return Scaffold(
      backgroundColor: _bgMain,
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _refresh,
              color: context.accent,
              backgroundColor: _bgSurface,
              child: ref.watch(feedProvider).when(
                    loading: () => const FeedSkeleton(),
                    error: (e, _) => ListView(children: [
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
                      final items =
                          _buildItems(posts, [for (final g in result.unreachable) g.displayName]);
                      // Trailing spinner row while the next page loads.
                      final showSpinner = _loadingMore && posts.isNotEmpty;
                      return ListView.builder(
                        controller: _scrollCtrl,
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
                              child:
                                  Center(child: CircularProgressIndicator(color: context.accent)),
                            );
                          }
                          return _buildItem(items[i], allView: allView);
                        },
                      );
                    },
                  ),
            ),
            // Floating search bar + active filter chips — slide away on scroll down.
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
    );
  }

  Widget _emptyState({required IconData icon, required String title, required String subtitle}) {
    return ListView(children: [
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
      if (_datePreset != null) _filterChip(_datePreset!, () => setState(() => _datePreset = null)),
      if (_location != null)
        _filterChip(_location!, () {
          setState(() => _location = null);
          ref.read(feedLocationProvider.notifier).state = null;
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
            color: context.accentLight,
            border: Border.all(color: context.accent),
            borderRadius: BorderRadius.circular(9999),
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
  });

  final VoidCallback onSearch;
  final VoidCallback onFilter;
  final bool filterActive;

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
    required this.datePreset,
    required this.locations,
    required this.selectedLocation,
  });

  /// Every connected group (signed-out ones offer re-login).
  final List<ServerAccount> groups;
  final Set<String> hiddenGroupIds;
  final void Function(ServerAccount) onRelogin;

  final List<_FilterPerson> authors;
  final Set<String> selectedPeople;
  final bool includeTagged;
  final String? datePreset;
  final List<({String location, int count})> locations;
  final String? selectedLocation;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final Set<String> _hidden = {...widget.hiddenGroupIds};
  late final Set<String> _people = {...widget.selectedPeople};
  late bool _includeTagged = widget.includeTagged;
  late String? _date = widget.datePreset;
  late String? _location = widget.selectedLocation;
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
      location: _location,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Reacts live to the pending group pills: deselect a group and its people vanish.
    final people = _visiblePeople;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 22),
      // Scrolls so the sheet can never overflow a compact screen (the EULA lesson).
      child: SingleChildScrollView(
          child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(9999)),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Filter',
                  style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
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
          const SizedBox(height: 18),
          // With a single connected group there is nothing to scope, so the whole GROUPS
          // section disappears - a one-group member never sees multi-group machinery.
          if (widget.groups.length > 1) ...[
            const Text('GROUPS',
                style: TextStyle(
                    color: _fgMuted,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    letterSpacing: 0.4)),
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
                        // Session expired there — run the (additive) login flow again.
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
                    color: _fgMuted,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    letterSpacing: 0.4)),
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
                                _personQuery.isEmpty ||
                                a.name.toLowerCase().contains(_personQuery)))
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
            children: [for (final d in _datePresets) _datePill(d)],
          ),
          if (widget.locations.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text('PLACES',
                style: TextStyle(
                    color: _fgMuted,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    letterSpacing: 0.4)),
            const SizedBox(height: 11),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final l in widget.locations) _placePill(l)],
                ),
              ),
            ),
          ],
          const SizedBox(height: 26),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    // Clearing everything includes the group scope: back to All.
                    _hidden.clear();
                    _people.clear();
                    _date = null;
                    _location = null;
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
                  child: const Text('Show results', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      )),
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
    final on = _date == label;
    return Semantics(
      button: true,
      selected: on,
      label: label,
      child: GestureDetector(
        onTap: () => setState(() => _date = on ? null : label),
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

  Widget _placePill(({String location, int count}) l) {
    final on = _location == l.location;
    return Semantics(
      button: true,
      selected: on,
      label: l.location,
      child: GestureDetector(
        onTap: () => setState(() => _location = on ? null : l.location),
        child: Container(
          padding: const EdgeInsets.fromLTRB(11, 8, 13, 8),
          decoration: BoxDecoration(
            color: on ? context.accent : Colors.transparent,
            border: Border.all(color: on ? context.accent : _border),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.place_outlined, size: 14, color: on ? context.onAccent : _fgMuted),
              const SizedBox(width: 5),
              Text(l.location,
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
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/skeletons.dart';
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

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _scrollCtrl = ScrollController();
  bool _searchHidden = false;
  double _lastScrollTop = 0;

  // Filter state.
  List<Post> _allPosts = [];
  final Set<int> _people = {}; // selected author ids
  bool _includeTagged = true; // also match posts the selected people are tagged in
  String? _datePreset;
  String? _location; // server-side place filter (mirrors feedLocationProvider)

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
      _allViewHint('Search works within one group — show just one group from the bubble first.');
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
            _people.contains(p.authorId) ||
            (_includeTagged && p.peopleIds.any(_people.contains)))
        .where((p) => _withinPreset(p.createdAt))
        .toList();
  }

  /// People present in the loaded feed — authors plus anyone tagged in a post — for the
  /// filter sheet, so you can filter by someone who only appears in photos.
  List<({int id, String name})> _authors() {
    final seen = <int>{};
    final out = <({int id, String name})>[];
    for (final p in _allPosts) {
      if (seen.add(p.authorId)) out.add((id: p.authorId, name: p.authorName));
      for (final person in p.people) {
        if (seen.add(person.id)) out.add((id: person.id, name: person.name));
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<void> _openFilter() async {
    // People/date/place filters are per-server, so they only apply when one group is
    // shown; group visibility itself lives in the group bubble now.
    if (!ref.read(multiSessionProvider).isSingleGroupView) {
      _allViewHint('Filters work within one group — show just one group from the bubble first.');
      return;
    }
    var locs = <({String location, int count})>[];
    try {
      locs = await ref.read(locationsProvider.future);
    } catch (_) {}
    if (!mounted) return;
    final result = await showModalBottomSheet<
        ({Set<int> people, bool includeTagged, String? date, String? location})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _FilterSheet(
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
    // Location filters server-side, so update the provider to refetch the feed.
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
    // Per-group search + filters only apply when exactly one group is shown.
    final singleGroup = session.isSingleGroupView;
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
                        final shown = ref.read(multiSessionProvider).shownGroups;
                        final where = shown.length > 1
                            ? ' in ${[for (final g in shown) g.displayName].join(', ')}'
                            : '';
                        return ListView(children: [
                          const SizedBox(height: 150),
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.photo_camera_outlined, size: 44, color: _fgMuted),
                                const SizedBox(height: 14),
                                Text('No check-ins yet$where',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: _fgSecondary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 6),
                                const Text('Tap + to share an update.',
                                    style: TextStyle(color: _fgMuted, fontSize: 13)),
                              ],
                            ),
                          ),
                        ]);
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
                        showFilter: singleGroup,
                        leading: const _GroupBubble(),
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

  Widget _activeChips() {
    final names = {for (final p in _allPosts) p.authorId: p.authorName};
    final chips = <Widget>[
      for (final id in _people)
        _filterChip(names[id] ?? 'Someone', () => setState(() => _people.remove(id))),
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
    this.showFilter = true,
    this.leading,
  });

  final VoidCallback onSearch;
  final VoidCallback onFilter;
  final bool filterActive;

  /// Whether the per-group filter button is shown (only when one group is in view).
  final bool showFilter;

  /// Optional control to the left of the search pill (the group bubble).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Row(
        children: [
          if (leading != null) leading!,
          Expanded(child: _pill(context)),
        ],
      ),
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
          if (showFilter)
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
            )
          else
            const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// A round trigger to the left of the search bar that opens the group menu. Hidden when
/// only one group is connected (nothing to toggle). A globe when every group is shown;
/// accent-filled with the shown count when a subset is.
class _GroupBubble extends ConsumerStatefulWidget {
  const _GroupBubble();

  @override
  ConsumerState<_GroupBubble> createState() => _GroupBubbleState();
}

class _GroupBubbleState extends ConsumerState<_GroupBubble> {
  final _anchorKey = GlobalKey();
  OverlayEntry? _menu;

  @override
  void dispose() {
    _menu?.remove();
    super.dispose();
  }

  void _toggleMenu() {
    if (_menu != null) {
      _closeMenu();
      return;
    }
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero);
    _menu = OverlayEntry(
      builder: (_) => _GroupMenu(
        anchorOrigin: origin,
        anchorSize: box.size,
        onClose: _closeMenu,
        onAddGroup: () {
          _closeMenu();
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen()));
        },
        onRelogin: (g) {
          _closeMenu();
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => AuthScreen(initialServer: g.baseUrl)));
        },
      ),
    );
    Overlay.of(context).insert(_menu!);
  }

  void _closeMenu() {
    _menu?.remove();
    _menu = null;
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(multiSessionProvider);
    if (session.signedIn.length <= 1) return const SizedBox.shrink();
    final showingAll = session.showingAll;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: GestureDetector(
        key: _anchorKey,
        onTap: _toggleMenu,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: showingAll ? _bgSurface : context.accent,
            shape: BoxShape.circle,
            border: Border.all(color: showingAll ? _border : context.accent),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withAlpha(76), blurRadius: 26, offset: const Offset(0, 10)),
            ],
          ),
          child: Icon(
            Icons.public,
            size: 22,
            color: showingAll ? _fgSecondary : context.onAccent,
          ),
        ),
      ),
    );
  }
}

/// The popover anchored under the group bubble: an "All groups" row plus one live-toggle
/// row per group (signed-out groups offer re-login), and an "Add group" action. Toggles
/// mutate [multiSessionProvider] and this widget rebuilds in place, so the menu stays open.
class _GroupMenu extends ConsumerWidget {
  const _GroupMenu({
    required this.anchorOrigin,
    required this.anchorSize,
    required this.onClose,
    required this.onAddGroup,
    required this.onRelogin,
  });

  final Offset anchorOrigin;
  final Size anchorSize;
  final VoidCallback onClose;
  final VoidCallback onAddGroup;
  final void Function(ServerAccount group) onRelogin;

  static const double _width = 244;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(multiSessionProvider);
    final notifier = ref.read(multiSessionProvider.notifier);
    final screen = MediaQuery.of(context).size;
    final left = anchorOrigin.dx.clamp(8.0, screen.width - _width - 8);
    final top = anchorOrigin.dy + anchorSize.height + 8;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: _width,
              decoration: BoxDecoration(
                color: _bgSurface,
                border: Border.all(color: _border),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withAlpha(120),
                      blurRadius: 30,
                      offset: const Offset(0, 14)),
                ],
              ),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _menuRow(
                    context,
                    leadingIcon: Icons.public,
                    label: 'All groups',
                    selected: session.showingAll,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      notifier.showAllGroups();
                    },
                  ),
                  const Divider(height: 1, color: _border),
                  for (final g in session.groups)
                    if (g.isSignedIn)
                      _menuRow(
                        context,
                        dotColor: g.displayColor,
                        label: g.displayName,
                        selected: !session.hiddenGroupIds.contains(g.id),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          notifier.toggleGroup(g.id);
                        },
                      )
                    else
                      _menuRow(
                        context,
                        leadingIcon: Icons.lock_outline,
                        label: g.displayName,
                        trailing: 'Log in',
                        muted: true,
                        onTap: () => onRelogin(g),
                      ),
                  const Divider(height: 1, color: _border),
                  _menuRow(
                    context,
                    leadingIcon: Icons.add,
                    label: 'Add group',
                    onTap: onAddGroup,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuRow(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
    IconData? leadingIcon,
    Color? dotColor,
    bool selected = false,
    bool muted = false,
    String? trailing,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: dotColor != null
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                      ),
                    )
                  : Icon(leadingIcon, size: 20, color: muted ? _fgMuted : _fgSecondary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: muted ? _fgMuted : _fgPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (trailing != null)
              Text(trailing,
                  style:
                      TextStyle(color: context.accent, fontSize: 13, fontWeight: FontWeight.w600))
            else if (selected)
              Icon(Icons.check, size: 19, color: context.accent),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet to filter the feed by person and date. Mutates the passed-in [selectedPeople]
/// set and reports the chosen date preset back via the result/closure.
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.authors,
    required this.selectedPeople,
    required this.includeTagged,
    required this.datePreset,
    required this.locations,
    required this.selectedLocation,
  });

  final List<({int id, String name})> authors;
  final Set<int> selectedPeople;
  final bool includeTagged;
  final String? datePreset;
  final List<({String location, int count})> locations;
  final String? selectedLocation;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final Set<int> _people = {...widget.selectedPeople};
  late bool _includeTagged = widget.includeTagged;
  late String? _date = widget.datePreset;
  late String? _location = widget.selectedLocation;
  String _personQuery = '';

  static const _palette = [
    Color(0xFF5557E0),
    Color(0xFF13AF9D),
    Color(0xFFDD1C85),
    Color(0xFFE9960A),
    Color(0xFF8458E9),
    Color(0xFF22C55E),
    Color(0xFFEF4444),
    Color(0xFF0EA5E9),
  ];

  void _apply() => Navigator.of(context).pop((
        people: _people,
        includeTagged: _includeTagged,
        date: _date,
        location: _location,
      ));

  @override
  Widget build(BuildContext context) {
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
          if (widget.authors.isNotEmpty) ...[
            const Text('PEOPLE',
                style: TextStyle(
                    color: _fgMuted,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    letterSpacing: 0.4)),
            const SizedBox(height: 10),
            if (widget.authors.length > 5) ...[
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
                for (final a in widget.authors.where(
                    (a) => _personQuery.isEmpty || a.name.toLowerCase().contains(_personQuery)))
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

  Widget _personChip(({int id, String name}) a) {
    final on = _people.contains(a.id);
    final color = _palette[a.id.abs() % _palette.length];
    return Semantics(
      button: true,
      selected: on,
      label: a.name,
      child: GestureDetector(
        onTap: () => setState(() => on ? _people.remove(a.id) : _people.add(a.id)),
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
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(a.name.isNotEmpty ? a.name[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11)),
              ),
              const SizedBox(width: 7),
              Text(a.name,
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../profile/profile_screen.dart';
import 'post_card.dart';
import 'user_search_delegate.dart';

// Design tokens
const _bgMain = Color(0xFF0A0A0B);
const _bgSurface = Color(0xFF1C1C1E);
const _bgSurfaceHover = Color(0xFF232326);
const _border = Color(0xFF27272A);
const _fgPrimary = Color(0xFFEDEDEF);
const _fgSecondary = Color(0xFFABABB0);
const _fgMuted = Color(0xFF848490);
const _accent = Color(0xFF5557E0);
const _accentLight = Color(0x295557E0);
const _onAccent = Colors.white;

const _datePresets = ['Today', 'This week', 'This month'];

/// A feed item that renders the section date label with connector lines.
class _DateDivider extends StatelessWidget {
  const _DateDivider({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(width: 2, height: 12, color: _accentLight),
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
        Container(width: 2, height: 12, color: _accentLight),
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
        Container(width: 2, height: 11, color: _accentLight),
        Container(
          width: 9,
          height: 9,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: const BoxDecoration(
            color: _accent,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: _accentLight, blurRadius: 0, spreadRadius: 3)],
          ),
        ),
        Container(width: 2, height: 11, color: _accentLight),
      ],
    );
  }
}

sealed class _FeedItem {}

class _DividerItem extends _FeedItem {
  _DividerItem(this.label);
  final String label;
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
  String? _datePreset;

  bool get _hasFilter => _people.isNotEmpty || _datePreset != null;

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
  }

  Future<void> _refresh() async {
    ref.invalidate(feedProvider);
    await ref.read(feedProvider.future);
  }

  Future<void> _openUserSearch() async {
    final user = await showSearch<User?>(
      context: context,
      delegate: UserSearchDelegate(ref.read(apiProvider)),
    );
    if (user != null && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProfileScreen(userId: user.id, isSelf: false)),
      );
    }
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
        .where((p) => _people.isEmpty || _people.contains(p.authorId))
        .where((p) => _withinPreset(p.createdAt))
        .toList();
  }

  /// Distinct authors present in the loaded feed, for the filter sheet.
  List<({int id, String name})> _authors() {
    final seen = <int>{};
    final out = <({int id, String name})>[];
    for (final p in _allPosts) {
      if (seen.add(p.authorId)) out.add((id: p.authorId, name: p.authorName));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<void> _openFilter() async {
    final result = await showModalBottomSheet<({Set<int> people, String? date})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _FilterSheet(
        authors: _authors(),
        selectedPeople: _people,
        datePreset: _datePreset,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _people
          ..clear()
          ..addAll(result.people);
        _datePreset = result.date;
      });
    }
  }

  List<_FeedItem> _buildItems(List<Post> posts) {
    final items = <_FeedItem>[];
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

  Widget _buildItem(_FeedItem item) {
    return switch (item) {
      _DividerItem(:final label) => _DateDivider(label: label),
      _GapItem() => const _GapConnector(),
      _PostItem(:final post) => PostCard(post: post),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgMain,
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _refresh,
              color: _accent,
              backgroundColor: _bgSurface,
              child: ref.watch(feedProvider).when(
                    loading: () => const Center(child: CircularProgressIndicator(color: _accent)),
                    error: (e, _) => ListView(children: [
                      const SizedBox(height: 140),
                      Center(
                        child: Text('Could not load feed.\n$e',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: _fgSecondary)),
                      ),
                    ]),
                    data: (data) {
                      _allPosts = data;
                      final posts = _applyFilter(_allPosts);
                      if (_allPosts.isEmpty) {
                        return ListView(children: const [
                          SizedBox(height: 180),
                          Center(
                            child: Text('No posts yet.\nTap + to share an update.',
                                textAlign: TextAlign.center, style: TextStyle(color: _fgMuted)),
                          ),
                        ]);
                      }
                      final items = _buildItems(posts);
                      return ListView.builder(
                        controller: _scrollCtrl,
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.only(top: _hasFilter ? 116 : 72, bottom: 24),
                        itemCount: posts.isEmpty ? 1 : items.length,
                        itemBuilder: (_, i) {
                          if (posts.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.only(top: 60),
                              child: Center(
                                child: Text('No posts match your filters.',
                                    style: TextStyle(color: _fgMuted)),
                              ),
                            );
                          }
                          return _buildItem(items[i]);
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
                        onSearch: _openUserSearch,
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

  Widget _activeChips() {
    final names = {for (final p in _allPosts) p.authorId: p.authorName};
    final chips = <Widget>[
      for (final id in _people)
        _filterChip(names[id] ?? 'Someone', () => setState(() => _people.remove(id))),
      if (_datePreset != null)
        _filterChip(_datePreset!, () => setState(() => _datePreset = null)),
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
    return GestureDetector(
      onTap: onRemove,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 5, 9, 5),
        decoration: BoxDecoration(
          color: _accentLight,
          border: Border.all(color: _accent),
          borderRadius: BorderRadius.circular(9999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(color: _accent, fontWeight: FontWeight.w600, fontSize: 12)),
            const SizedBox(width: 5),
            const Icon(Icons.close, size: 15, color: _accent),
          ],
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
      child: Container(
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
            const Icon(Icons.search, size: 19, color: _fgMuted),
            const SizedBox(width: 9),
            Expanded(
              child: GestureDetector(
                onTap: onSearch,
                behavior: HitTestBehavior.opaque,
                child: const Text('Search people',
                    style: TextStyle(color: _fgMuted, fontSize: 14)),
              ),
            ),
            GestureDetector(
              onTap: onFilter,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: filterActive ? _accent : _bgSurfaceHover,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.filter_list,
                    size: 19, color: filterActive ? _onAccent : _fgSecondary),
              ),
            ),
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
    required this.datePreset,
  });

  final List<({int id, String name})> authors;
  final Set<int> selectedPeople;
  final String? datePreset;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final Set<int> _people = {...widget.selectedPeople};
  late String? _date = widget.datePreset;

  static const _palette = [
    Color(0xFF5557E0), Color(0xFF13AF9D), Color(0xFFDD1C85),
    Color(0xFFE9960A), Color(0xFF8458E9), Color(0xFF22C55E),
    Color(0xFFEF4444), Color(0xFF0EA5E9),
  ];

  void _apply() => Navigator.of(context).pop((people: _people, date: _date));

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38, height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(9999)),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Filter',
                  style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 30, height: 30,
                  decoration: const BoxDecoration(color: _bgSurfaceHover, shape: BoxShape.circle),
                  child: const Icon(Icons.close, size: 18, color: _fgSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (widget.authors.isNotEmpty) ...[
            const Text('PEOPLE',
                style: TextStyle(
                    color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 0.4)),
            const SizedBox(height: 11),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in widget.authors) _personChip(a),
              ],
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
          const SizedBox(height: 26),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _people.clear();
                    _date = null;
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
                    backgroundColor: _accent,
                    foregroundColor: _onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Show results',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _personChip(({int id, String name}) a) {
    final on = _people.contains(a.id);
    final color = _palette[a.id.abs() % _palette.length];
    return GestureDetector(
      onTap: () => setState(() => on ? _people.remove(a.id) : _people.add(a.id)),
      child: Container(
        padding: const EdgeInsets.fromLTRB(5, 5, 13, 5),
        decoration: BoxDecoration(
          color: on ? _accent : Colors.transparent,
          border: Border.all(color: on ? _accent : _border),
          borderRadius: BorderRadius.circular(9999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text(a.name.isNotEmpty ? a.name[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11)),
            ),
            const SizedBox(width: 7),
            Text(a.name,
                style: TextStyle(
                    color: on ? _onAccent : _fgSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _datePill(String label) {
    final on = _date == label;
    return GestureDetector(
      onTap: () => setState(() => _date = on ? null : label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
        decoration: BoxDecoration(
          color: on ? _accent : Colors.transparent,
          border: Border.all(color: on ? _accent : _border),
          borderRadius: BorderRadius.circular(9999),
        ),
        child: Text(label,
            style: TextStyle(
                color: on ? _onAccent : _fgSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
      ),
    );
  }
}

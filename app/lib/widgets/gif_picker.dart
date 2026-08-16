import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../theme/accent.dart';
import '../theme/tokens.dart';

/// Fetches one page of gif results for [query] (empty = trending). Matches
/// `ApiClient.gifSearch`'s shape but as a bare function, so a widget test can hand the
/// picker a fake without building a whole fake ApiClient/Dio stack.
typedef GifSearch = Future<GifSearchPage> Function(String query, int page);

/// How long typing pauses before a search fires - long enough that a normal typing cadence
/// never fires one request per keystroke, short enough that the result still feels live.
const kGifSearchDebounce = Duration(milliseconds: 350);

/// Opens the Klipy gif picker as a bottom sheet: a search field, trending shown on open,
/// and an infinite-scrolling grid of previews. Resolves with the chosen [GifResult], or null
/// if the sheet is dismissed without a pick.
Future<GifResult?> showGifPicker(BuildContext context, {required GifSearch search}) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<GifResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _GifPickerSheet(search: search),
  );
}

class _GifPickerSheet extends StatefulWidget {
  const _GifPickerSheet({required this.search});

  final GifSearch search;

  @override
  State<_GifPickerSheet> createState() => _GifPickerSheetState();
}

class _GifPickerSheetState extends State<_GifPickerSheet> {
  final _queryCtrl = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  String _activeQuery = '';
  int _page = 1;
  bool _hasNext = false;
  List<GifResult> _gifs = [];
  bool _loading = true; // the initial (or a reset) load
  bool _loadingMore = false; // an infinite-scroll page beyond the first
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryCtrl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasNext || _loading || _loadingMore) return;
    // Fire the next page a bit before the very bottom, so scrolling feels continuous rather
    // than pausing on a spinner at the edge.
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      _load(reset: false);
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(kGifSearchDebounce, () {
      if (!mounted) return;
      final trimmed = value.trim();
      if (trimmed == _activeQuery) return;
      _activeQuery = trimmed;
      _load(reset: true);
    });
  }

  Future<void> _load({required bool reset}) async {
    final page = reset ? 1 : _page + 1;
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final result = await widget.search(_activeQuery, page);
      if (!mounted) return;
      setState(() {
        _gifs = reset ? result.gifs : [..._gifs, ...result.gifs];
        _hasNext = result.hasNext;
        _page = page;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (reset) _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75 - bottomInset,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queryCtrl,
                        autofocus: false,
                        onChanged: _onQueryChanged,
                        style: const TextStyle(color: kFgPrimary, fontSize: 14),
                        cursorColor: context.accent,
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 18, color: kFgMuted),
                          hintText: 'Search gifs',
                          hintStyle: const TextStyle(color: kFgMuted, fontSize: 14),
                          filled: true,
                          fillColor: kBgMain,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: kBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: context.accent),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: kFgMuted),
                    ),
                  ],
                ),
              ),
              Expanded(child: _body()),
              _attribution(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: context.accent));
    }
    if (_error != null) {
      return _message(
        icon: Icons.wifi_off_rounded,
        text: "Couldn't load gifs. Check your connection.",
        actionLabel: 'Try again',
        onAction: () => _load(reset: true),
      );
    }
    if (_gifs.isEmpty) {
      return _message(
        icon: Icons.search_off_rounded,
        text: _activeQuery.isEmpty
            ? 'No gifs to show right now.'
            : 'No gifs found for "$_activeQuery".',
      );
    }
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          _grid(),
          if (_loadingMore)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Center(
                  child: SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: context.accent))),
            ),
        ],
      ),
    );
  }

  /// A two-column masonry: each gif joins whichever column is currently shorter, so tiles of
  /// differing aspect ratios stay roughly level rather than leaving a ragged column of gaps
  /// the way a fixed-row grid would with mixed-ratio previews.
  Widget _grid() {
    final left = <GifResult>[];
    final right = <GifResult>[];
    var leftHeight = 0.0;
    var rightHeight = 0.0;
    for (final g in _gifs) {
      final relativeHeight = 1 / (g.previewAspectRatio ?? 1);
      if (leftHeight <= rightHeight) {
        left.add(g);
        leftHeight += relativeHeight;
      } else {
        right.add(g);
        rightHeight += relativeHeight;
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(children: [for (final g in left) _tile(g)])),
        const SizedBox(width: 8),
        Expanded(child: Column(children: [for (final g in right) _tile(g)])),
      ],
    );
  }

  Widget _tile(GifResult g) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).pop(g);
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(
            aspectRatio: g.previewAspectRatio ?? 1,
            child: Semantics(
              label: g.title.isEmpty ? 'gif' : g.title,
              button: true,
              child: Image.network(
                g.previewUrl,
                fit: BoxFit.cover,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: frame == null ? const ColoredBox(color: kBgSurfaceHover) : child,
                  );
                },
                errorBuilder: (_, __, ___) => const ColoredBox(
                  color: kBgSurfaceHover,
                  child: Icon(Icons.broken_image_outlined, color: kFgMuted, size: 20),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _message({
    required IconData icon,
    required String text,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: kFgMuted, size: 32),
            const SizedBox(height: 10),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: kFgSecondary)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 10),
              TextButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }

  /// Klipy's API terms require attribution wherever results are shown.
  Widget _attribution() => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text('Powered by KLIPY',
            style: TextStyle(color: kFgMuted.withValues(alpha: 0.8), fontSize: 11)),
      );
}

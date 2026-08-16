import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';

import '../../api/models.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/media_frame.dart';
import '../../widgets/user_avatar.dart';

const _bgSurface = kBgSurface;
const _bgSurfaceHover = kBgSurfaceHover;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;

/// RecapDeck renders a recap post's panels as a swipeable, PageView deck - the collage
/// ("The Wall") and/or awards ("Awards Night") panels the payload carries.
///
/// A panel type this client doesn't recognise never reaches here at all: [Post.fromJson]
/// drops it via [RecapPanel.tryParse], which is the forward-compat contract that lets a
/// v1.5+ server add new panel types without breaking this client. When that leaves zero
/// panels, the deck falls back to a plain stats summary rather than rendering nothing.
class RecapDeck extends StatefulWidget {
  const RecapDeck({super.key, required this.recap, required this.groupId});

  final RecapPayload recap;
  final String? groupId;

  @override
  State<RecapDeck> createState() => _RecapDeckState();
}

class _RecapDeckState extends State<RecapDeck> {
  final _controller = PageController();
  final Map<int, GlobalKey> _boundaryKeys = {};
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(int index) => _boundaryKeys.putIfAbsent(index, () => GlobalKey());

  /// Rasterizes the current panel's [RepaintBoundary] and saves it to the device gallery -
  /// the v1 "generated image" flow. Zero new dependencies: both halves already exist
  /// in-tree (photo_crop_screen.dart's capture, post_card.dart's Gal save).
  Future<void> _savePanel(int index) async {
    try {
      final boundary = _keyFor(index).currentContext!.findRenderObject() as RenderRepaintBoundary;
      final pixelRatio = (1080.0 / boundary.size.width).clamp(1.0, 4.0);
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      await Gal.putImageBytes(data.buffer.asUint8List());
      _snack('Saved to your photos');
    } on GalException catch (_) {
      _snack('Allow photo access to save this');
    } catch (_) {
      _snack('Could not save this panel');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final panels = widget.recap.panels;
    if (panels.isEmpty) {
      return _RecapStatsFallback(recap: widget.recap);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 4 / 5,
          child: PageView.builder(
            controller: _controller,
            itemCount: panels.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, index) => RepaintBoundary(
              key: _keyFor(index),
              child: _RecapPanelView(panel: panels[index], groupId: widget.groupId),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < panels.length; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page ? context.accent : _border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              const SizedBox(width: 12),
              Semantics(
                button: true,
                label: 'Save this panel to your photos',
                child: Material(
                  color: Colors.transparent,
                  child: InkResponse(
                    onTap: () => _savePanel(_page),
                    radius: 20,
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.download_outlined, size: 18, color: _fgMuted),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Dispatches to the right panel renderer. panel is one of the two v1 subtypes
/// ([RecapCollagePanel], [RecapAwardsPanel]) by construction - [RecapPanel.tryParse] never
/// hands back anything else - so the switch is exhaustive with no default case.
class _RecapPanelView extends StatelessWidget {
  const _RecapPanelView({required this.panel, required this.groupId});

  final RecapPanel panel;
  final String? groupId;

  @override
  Widget build(BuildContext context) => switch (panel) {
        RecapCollagePanel p => _WallPanel(panel: p, groupId: groupId),
        RecapAwardsPanel p => _AwardsPanel(panel: p, groupId: groupId),
      };
}

/// "The Wall": the ranked collage, fridge-door style - a grid of tiles each carrying the
/// author's name (and, for a text-only guaranteed slot, a quote card instead of a photo).
class _WallPanel extends StatelessWidget {
  const _WallPanel({required this.panel, required this.groupId});

  final RecapCollagePanel panel;
  final String? groupId;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: _bgSurface),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(panel.title,
                  style: const TextStyle(
                      color: _fgPrimary, fontWeight: FontWeight.w800, fontSize: 18)),
            ),
            Expanded(
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.85,
                ),
                itemCount: panel.cards.length,
                itemBuilder: (context, i) => _WallTile(card: panel.cards[i], groupId: groupId),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WallTile extends StatelessWidget {
  const _WallTile({required this.card, required this.groupId});

  final RecapCard card;
  final String? groupId;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _WallTileContent(card: card, groupId: groupId),
          Positioned(
            left: 6,
            right: 6,
            top: 6,
            child: Row(
              children: [
                UserAvatar(
                  name: card.authorName,
                  size: 20,
                  mediaId: card.authorPhotoId,
                  colorSeed: card.authorId,
                  groupId: groupId,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    card.authorName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (card.rank == 1)
            const Positioned(
              top: 6,
              right: 6,
              child: Icon(Icons.star_rounded, color: Colors.amber, size: 18, shadows: [
                Shadow(color: Colors.black54, blurRadius: 4),
              ]),
            ),
        ],
      ),
    );
  }
}

/// The tile's body: the photo/clip attachment, a quote card, or - when a photo/clip card's
/// media is missing (a deleted attachment; the payload's frozen mediaId can outlive the
/// file it named) - a tasteful "removed" placeholder rather than a broken layout.
class _WallTileContent extends StatelessWidget {
  const _WallTileContent({required this.card, required this.groupId});

  final RecapCard card;
  final String? groupId;

  @override
  Widget build(BuildContext context) {
    if (card.isQuote) {
      return Container(
        color: context.accent.withValues(alpha: 0.18),
        padding: const EdgeInsets.all(10),
        alignment: Alignment.center,
        child: Text(
          card.body,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _fgPrimary, fontWeight: FontWeight.w600, fontSize: 13),
        ),
      );
    }
    final media = card.media;
    if (media == null) {
      return Container(
        color: _bgSurfaceHover,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported_outlined, color: _fgMuted, size: 28),
      );
    }
    return MediaFrame(media: media, groupId: groupId);
  }
}

/// "Awards Night": the period's superlatives, one row per award.
class _AwardsPanel extends StatelessWidget {
  const _AwardsPanel({required this.panel, required this.groupId});

  final RecapAwardsPanel panel;
  final String? groupId;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: _bgSurface),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(panel.title,
                style:
                    const TextStyle(color: _fgPrimary, fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: panel.awards.length,
                separatorBuilder: (_, __) => const Divider(color: _border, height: 20),
                itemBuilder: (context, i) => _AwardRow(award: panel.awards[i], groupId: groupId),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AwardRow extends StatelessWidget {
  const _AwardRow({required this.award, required this.groupId});

  final RecapAward award;
  final String? groupId;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        UserAvatar(
          name: award.userName,
          size: 34,
          mediaId: award.userPhotoId,
          colorSeed: award.userId,
          groupId: groupId,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(award.label,
                  style: const TextStyle(
                      color: _fgSecondary, fontWeight: FontWeight.w600, fontSize: 12)),
              Text(award.userName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 15)),
            ],
          ),
        ),
        Text(award.value, style: const TextStyle(color: _fgMuted, fontSize: 13)),
      ],
    );
  }
}

/// Shown when a recap payload has zero panels this client recognises (every panel type in
/// it is newer than this build understands) - a plain stats summary rather than an empty
/// deck, mirroring the caption-only fallback older client generations get entirely.
class _RecapStatsFallback extends StatelessWidget {
  const _RecapStatsFallback({required this.recap});

  final RecapPayload recap;

  @override
  Widget build(BuildContext context) {
    final s = recap.stats;
    final unit = recap.cadence == 'monthly' ? 'month' : 'period';
    return Container(
      color: _bgSurface,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome_outlined, color: _fgMuted, size: 28),
          const SizedBox(height: 8),
          Text('${s.posts} check-ins this $unit',
              style: const TextStyle(color: _fgPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 4),
          const Text('Update Check-In to see the full recap.',
              style: TextStyle(color: _fgMuted, fontSize: 12)),
        ],
      ),
    );
  }
}

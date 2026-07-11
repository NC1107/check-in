import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A gently pulsing set of placeholder cards shown while the feed (or profile) loads, so
/// the screen reads as "content is coming" instead of a blank spinner. Dependency-free: a
/// slow opacity pulse on grey blocks shaped like a post card.
class FeedSkeleton extends StatefulWidget {
  const FeedSkeleton({super.key, this.count = 3, this.topPadding = 80});

  final int count;
  final double topPadding;

  @override
  State<FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<FeedSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) {
        final o = 0.35 + 0.35 * _pulse.value; // 0.35 → 0.70
        return ListView(
          primary: false,
          padding: EdgeInsets.only(top: widget.topPadding, bottom: 24),
          physics: const NeverScrollableScrollPhysics(),
          children: [for (var i = 0; i < widget.count; i++) _card(o)],
        );
      },
    );
  }

  Widget _block(double? width, double height, double o, {double radius = 6}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: kBgSurfaceHover.withValues(alpha: o),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }

  Widget _card(double o) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBgSurface,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: kBgSurfaceHover.withValues(alpha: o),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _block(120, 12, o),
                  const SizedBox(height: 6),
                  _block(80, 10, o),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          _block(double.infinity, 12, o),
          const SizedBox(height: 8),
          _block(220, 12, o),
          const SizedBox(height: 14),
          _block(double.infinity, 168, o, radius: 10),
        ],
      ),
    );
  }
}

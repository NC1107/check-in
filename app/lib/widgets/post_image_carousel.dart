import 'package:flutter/material.dart';

import 'auth_image.dart';

/// Renders a post's image(s) to fill its parent (place inside an AspectRatio). A single
/// image shows directly; multiple images become a swipeable carousel with page dots and
/// a counter pill.
class PostImageCarousel extends StatefulWidget {
  const PostImageCarousel({super.key, required this.mediaIds});

  final List<int> mediaIds;

  @override
  State<PostImageCarousel> createState() => _PostImageCarouselState();
}

class _PostImageCarouselState extends State<PostImageCarousel> {
  final _ctrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.mediaIds;
    if (ids.isEmpty) return const SizedBox.shrink();
    if (ids.length == 1) return AuthImage(mediaId: ids.first);
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          controller: _ctrl,
          itemCount: ids.length,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (_, i) => AuthImage(mediaId: ids[i]),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(9999),
            ),
            child: Text('${_page + 1}/${ids.length}',
                style: const TextStyle(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ),
        Positioned(
          bottom: 8,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < ids.length; i++)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: i == _page ? Colors.white : Colors.white.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

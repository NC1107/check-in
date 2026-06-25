import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';

/// AuthImage loads a media id from the server, sending the bearer token via headers so
/// the authenticated /api/media endpoint serves it. Caches like any network image.
class AuthImage extends ConsumerWidget {
  const AuthImage({super.key, required this.mediaId, this.fit = BoxFit.cover});

  final int mediaId;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    return CachedNetworkImage(
      imageUrl: api.imageUrl(mediaId),
      cacheKey: 'media-$mediaId', // stable across rebuilds → no re-fetch flash
      httpHeaders: api.authHeaders,
      fit: fit,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (c, _) => const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      errorWidget: (c, _, __) => const ColoredBox(
        color: Color(0x11000000),
        child: Icon(Icons.broken_image_outlined),
      ),
    );
  }
}

/// Avatar shows a user's profile picture (by media id) or a fallback initial.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.mediaId, this.radius = 20});

  final String name;
  final int? mediaId;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (mediaId == null) {
      final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
      return CircleAvatar(radius: radius, child: Text(initial));
    }
    return CircleAvatar(
      radius: radius,
      child: ClipOval(
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: AuthImage(mediaId: mediaId!),
        ),
      ),
    );
  }
}

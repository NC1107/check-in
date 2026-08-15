import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';

/// AuthImage loads a media id from the server, sending the bearer token via headers so
/// the authenticated /api/media endpoint serves it. Caches like any network image.
///
/// [groupId] says which connected group the media belongs to (null = the current
/// group). Media ids are only unique per server, so both the request and the cache key
/// must be scoped to the group - otherwise group B's photo 5 would render group A's.
class AuthImage extends ConsumerWidget {
  const AuthImage({
    super.key,
    required this.mediaId,
    this.fit = BoxFit.cover,
    this.groupId,
    this.variant,
    this.onImageResolved,
  });

  final int mediaId;
  final BoxFit fit;
  final String? groupId;

  /// Which stored file to show for this media id: null for the media itself, 'poster' for
  /// a clip's still frame. It scopes the cache key as well as the URL - a poster and its
  /// clip share an id, so one key for both would serve whichever was fetched first to
  /// both, e.g. rendering the poster where the full photo belongs.
  final String? variant;

  /// Called once this exact image has decoded successfully, with its intrinsic size (e.g.
  /// so a caller can size a box to the photo's real aspect ratio). Reading the size off the
  /// same provider that is actually being displayed - rather than a second, separate
  /// resolve - means this can never fail (and silently freeze a caller's layout) on its own;
  /// it only ever reports a size for an image that is already visibly showing.
  final ValueChanged<ImageInfo>? onImageResolved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(contentAccountProvider(groupId));
    final api = ref.watch(contentApiProvider(groupId));
    final onResolved = onImageResolved;
    return CachedNetworkImage(
      imageUrl: api.imageUrl(mediaId, variant: variant),
      // Group-scoped, variant-scoped, and stable across rebuilds → no re-fetch flash, no
      // cross-group collisions on the per-server media ids, no clip/poster collision.
      cacheKey: 'media-${account?.id ?? ''}-$mediaId${variant == null ? '' : '-$variant'}',
      httpHeaders: api.authHeaders,
      fit: fit,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      imageBuilder: onResolved == null
          ? null
          : (context, imageProvider) {
              final stream = imageProvider.resolve(ImageConfiguration.empty);
              late ImageStreamListener listener;
              listener = ImageStreamListener((info, _) {
                onResolved(info);
                stream.removeListener(listener);
              });
              stream.addListener(listener);
              return Image(image: imageProvider, fit: fit);
            },
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

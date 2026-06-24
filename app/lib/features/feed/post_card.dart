import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../widgets/auth_image.dart';
import '../post/post_detail_screen.dart';
import '../profile/profile_screen.dart';

/// PostCard renders one post in the feed with a like toggle and a comment shortcut.
class PostCard extends ConsumerStatefulWidget {
  const PostCard({super.key, required this.post});

  final Post post;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  late bool _liked = widget.post.likedByViewer;
  late int _likes = widget.post.likeCount;

  Future<void> _toggleLike() async {
    final api = ref.read(apiProvider);
    setState(() {
      _liked = !_liked;
      _likes += _liked ? 1 : -1;
    });
    try {
      _liked ? await api.like(widget.post.id) : await api.unlike(widget.post.id);
    } catch (_) {
      setState(() {
        _liked = !_liked;
        _likes += _liked ? 1 : -1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Avatar(name: p.authorName, mediaId: p.authorPhotoId),
            title: Text(p.authorName, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(DateFormat.yMMMd().add_jm().format(p.createdAt.toLocal())),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProfileScreen(userId: p.authorId, isSelf: false),
            )),
          ),
          if (p.kind == 'image' && p.mediaId != null)
            AspectRatio(aspectRatio: 1, child: AuthImage(mediaId: p.mediaId!)),
          if (p.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(p.body),
            ),
          Row(
            children: [
              IconButton(
                icon: Icon(_liked ? Icons.favorite : Icons.favorite_border,
                    color: _liked ? Colors.red : null),
                onPressed: _toggleLike,
              ),
              Text('$_likes'),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.mode_comment_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PostDetailScreen(postId: p.id),
                )),
              ),
              Text('${p.commentCount}'),
            ],
          ),
        ],
      ),
    );
  }
}

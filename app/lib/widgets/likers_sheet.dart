import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../features/profile/profile_screen.dart';
import '../state/app_state.dart';
import '../theme/accent.dart';
import '../theme/tokens.dart';
import 'user_avatar.dart';

/// Pulls up the list of members who liked [postId] from the bottom. The server only serves
/// this to the post's own author, so callers gate the entry point (a long-press on the like
/// button) to the author too.
Future<void> showLikersSheet(BuildContext context, {required int postId, String? groupId}) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _LikersSheet(postId: postId, groupId: groupId),
  );
}

class _LikersSheet extends ConsumerStatefulWidget {
  const _LikersSheet({required this.postId, this.groupId});

  final int postId;
  final String? groupId;

  @override
  ConsumerState<_LikersSheet> createState() => _LikersSheetState();
}

class _LikersSheetState extends ConsumerState<_LikersSheet> {
  late final Future<List<User>> _future =
      ref.read(contentApiProvider(widget.groupId)).postLikers(widget.postId);

  void _openProfile(int userId) {
    if (userId <= 0) return;
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProfileScreen(userId: userId, groupId: widget.groupId),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<User>>(
        future: _future,
        builder: (context, snap) {
          final likers = snap.data;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  likers == null || likers.isEmpty
                      ? 'Liked by'
                      : '${likers.length} ${likers.length == 1 ? 'like' : 'likes'}',
                  style:
                      const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              if (snap.connectionState == ConnectionState.waiting)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator(color: context.accent)),
                )
              else if (snap.hasError)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 28),
                  child:
                      Text('Could not load who liked this.', style: TextStyle(color: kFgSecondary)),
                )
              else if (likers == null || likers.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 28),
                  child: Text('No likes yet.', style: TextStyle(color: kFgMuted)),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final u in likers)
                        ListTile(
                          leading: UserAvatar(
                              name: u.name,
                              mediaId: u.profileMediaId,
                              size: 38,
                              colorSeed: u.id,
                              groupId: widget.groupId),
                          title:
                              Text(u.name, style: const TextStyle(color: kFgPrimary, fontSize: 15)),
                          onTap: () => _openProfile(u.id),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

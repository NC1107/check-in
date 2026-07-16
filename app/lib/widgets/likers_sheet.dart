import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../features/profile/profile_screen.dart';
import '../state/app_state.dart';
import '../theme/accent.dart';
import '../theme/tokens.dart';
import 'user_avatar.dart';

/// One place a post's likes live: its id on a particular group's server.
typedef _LikerSource = ({int postId, String? groupId});

/// A liker plus which group's server they liked on (null in a single-group view).
typedef _TaggedLiker = ({User user, String? groupId});

/// Pulls up the list of members who liked a post from the bottom. The server serves this
/// only to the post's own author, so callers gate the entry point (a long-press on the like
/// button) to the author too. Pass [copies] for a cross-post to merge likers from every
/// group it was shared to, each tagged with its group; otherwise pass [postId]/[groupId].
Future<void> showLikersSheet(BuildContext context,
    {int? postId, String? groupId, List<PostCopy>? copies}) {
  HapticFeedback.selectionClick();
  final sources = <_LikerSource>[
    if (copies != null && copies.isNotEmpty)
      for (final c in copies) (postId: c.postId, groupId: c.groupId)
    else
      (postId: postId!, groupId: groupId),
  ];
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _LikersSheet(sources: sources),
  );
}

class _LikersSheet extends ConsumerStatefulWidget {
  const _LikersSheet({required this.sources});

  final List<_LikerSource> sources;

  @override
  ConsumerState<_LikersSheet> createState() => _LikersSheetState();
}

class _LikersSheetState extends ConsumerState<_LikersSheet> {
  late final Future<List<_TaggedLiker>> _future = _load();

  /// Fetches likers from each source in turn, tagging every liker with its group. Best
  /// effort: a group that can't be reached contributes nothing rather than failing the whole.
  Future<List<_TaggedLiker>> _load() async {
    final out = <_TaggedLiker>[];
    for (final s in widget.sources) {
      try {
        final users = await ref.read(contentApiProvider(s.groupId)).postLikers(s.postId);
        for (final u in users) {
          out.add((user: u, groupId: s.groupId));
        }
      } catch (_) {}
    }
    return out;
  }

  ServerAccount? _account(String? groupId) {
    if (groupId == null) return null;
    for (final a in ref.read(multiSessionProvider).signedIn) {
      if (a.id == groupId) return a;
    }
    return null;
  }

  void _openProfile(int userId, String? groupId) {
    if (userId <= 0) return;
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProfileScreen(userId: userId, groupId: groupId),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final multiGroup = widget.sources.length > 1;
    return SafeArea(
      child: FutureBuilder<List<_TaggedLiker>>(
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
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: likers.length,
                    itemBuilder: (_, i) {
                      final u = likers[i].user;
                      final gid = likers[i].groupId;
                      return ListTile(
                        leading: UserAvatar(
                            name: u.name,
                            mediaId: u.profileMediaId,
                            size: 38,
                            colorSeed: u.id,
                            groupId: gid),
                        title:
                            Text(u.name, style: const TextStyle(color: kFgPrimary, fontSize: 15)),
                        // Which group they liked in only matters once more than one is merged.
                        trailing: multiGroup ? _groupBadge(gid) : null,
                        onTap: () => _openProfile(u.id, gid),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }

  Widget? _groupBadge(String? groupId) {
    final acct = _account(groupId);
    if (acct == null) return null;
    final color = acct.displayColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.16), kBgSurface),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Text(acct.displayName,
              style:
                  const TextStyle(color: kFgSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

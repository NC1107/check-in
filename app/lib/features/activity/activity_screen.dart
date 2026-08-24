import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../notifications/notification_route.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/user_avatar.dart';
import '../post/post_detail_screen.dart';

/// The log of what happened about you: comments on your check-ins, replies to your
/// comments, likes on your check-ins.
///
/// It exists because a push notification is the only record of most of those, and a
/// notification is gone the moment it is swiped away or missed. The server derives this
/// from the rows that already exist rather than from a log written at notify time (see the
/// Go side's db/activity.go), so it covers a member's whole history rather than starting
/// empty on the day it shipped.
///
/// Merged across groups, like the profile: one human, one list. Each item is stamped with
/// the group it came from, because ids are only unique per server and a tap has to go back
/// to the right one.

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return DateFormat.MMMd().format(dt.toLocal());
}

/// What an item says happened. Deliberately the flattest wording available - the row's job
/// is to be scanned, and the personality belongs in the check-ins themselves.
String activityLine(ActivityItem item) => switch (item.kind) {
      'comment' => '${item.actorName} commented on your check-in',
      'reply' => '${item.actorName} replied to your comment',
      'like' => '${item.actorName} liked your check-in',
      _ => item.actorName,
    };

/// The groups that can contribute to the list: signed in, and running a server new enough
/// to have the route at all. An older group is left out rather than 404ing every refresh.
List<ServerAccount> activityGroups(MultiSession session) => [
      for (final g in session.signedIn)
        if (g.activityCapable) g
    ];

/// Merges each group's page into one list, newest first, stamping every item with its
/// group. Sorted here rather than trusting arrival order, which is what keeps a slow
/// group's items from landing at the bottom regardless of when they happened.
List<ActivityItem> mergeActivity(Map<String, List<ActivityItem>> byGroup) {
  final all = <ActivityItem>[
    for (final e in byGroup.entries)
      for (final item in e.value) item.withGroup(e.key),
  ];
  all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return all;
}

/// One group's activity as fetched.
typedef _Fetched = ({List<ActivityItem> items, String name});

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  late Future<(List<ActivityItem>, List<String>)> _future = _load();

  Future<(List<ActivityItem>, List<String>)> _load() async {
    final groups = activityGroups(ref.read(multiSessionProvider));
    if (groups.isEmpty) return (<ActivityItem>[], <String>[]);

    final pages = await Future.wait([
      for (final g in groups)
        ref
            .read(apiForGroupProvider(g.id))
            .activity()
            .then<_Fetched?>((page) => (items: page.items, name: g.displayName))
            .catchError((_) => null),
    ]);

    final byGroup = <String, List<ActivityItem>>{};
    final unreachable = <String>[];
    for (var i = 0; i < groups.length; i++) {
      final page = pages[i];
      if (page == null) {
        unreachable.add(groups[i].displayName);
      } else {
        byGroup[groups[i].id] = page.items;
      }
    }
    // Reading the list is what clears the bell. Best-effort and per group: a group that
    // could not be reached keeps its unread count and clears on the next visit.
    for (final id in byGroup.keys) {
      unawaited(ref.read(apiForGroupProvider(id)).markActivitySeen().catchError((_) {}));
    }
    return (mergeActivity(byGroup), unreachable);
  }

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f.then((_) {}).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final multi = ref.watch(multiSessionProvider).signedIn.length > 1;
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        iconTheme: const IconThemeData(color: kFgSecondary),
        title: const Text('Activity',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: FutureBuilder<(List<ActivityItem>, List<String>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const FeedSkeleton(topPadding: 12);
          }
          if (snap.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not load your activity.',
                      style: TextStyle(color: kFgSecondary)),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _refresh, child: const Text('Try again')),
                ],
              ),
            );
          }
          final (items, unreachable) = snap.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              // The rows carry their own padding, but with none here the first one crowds
              // the title bar and the last sits flush against the bottom edge.
              padding: const EdgeInsets.only(top: 6, bottom: 16),
              children: [
                if (unreachable.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                    child: Text(
                      "Couldn't reach ${unreachable.join(', ')} - showing the rest.",
                      style: const TextStyle(color: kFgMuted, fontSize: 12.5),
                    ),
                  ),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 64, 24, 24),
                    child: Center(
                      child: Text(
                        'Nothing yet.\n'
                        'Comments, replies and likes on your check-ins show up here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kFgMuted, height: 1.5),
                      ),
                    ),
                  )
                else
                  ...items.map((i) => _row(i, showGroup: multi)),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Opens what this item is about, through the same route a notification tap opens - so
  /// finding a missed notification here lands exactly where following it would have.
  void _open(String groupId, ActivityItem item) {
    // Make sure the group is visible in the feed when the member comes back to it.
    ref.read(multiSessionProvider.notifier).showGroup(groupId);
    Navigator.of(context).push(PostDetailScreen.routeForNotification(
      NotificationRoute(groupId: groupId, postId: item.postId, commentId: item.commentId),
    ));
  }

  Widget _row(ActivityItem item, {required bool showGroup}) {
    final groupId = item.groupId;
    final group = ref.read(multiSessionProvider).byId(groupId);
    return InkWell(
      onTap: groupId == null ? null : () => _open(groupId, item),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UserAvatar(
              name: item.actorName,
              mediaId: item.actorPhotoId,
              size: 36,
              colorSeed: item.actorId,
              groupId: groupId,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(activityLine(item),
                            style: const TextStyle(color: kFgPrimary, fontSize: 14)),
                      ),
                      const SizedBox(width: 8),
                      Text(_relativeTime(item.createdAt),
                          style: const TextStyle(color: kFgMuted, fontSize: 11)),
                    ],
                  ),
                  if (item.preview.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(item.preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kFgSecondary, fontSize: 13, height: 1.35)),
                  ],
                  if (showGroup && group != null) ...[
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration:
                              BoxDecoration(color: group.displayColor, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                        Text(group.displayName,
                            style: const TextStyle(color: kFgMuted, fontSize: 11)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

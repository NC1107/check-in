import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import 'activity_screen.dart';

/// The bell on the profile, and the dot on it.
///
/// The count is summed across groups because the member is one person with one list, and
/// it comes from each server rather than from this device: reading the list on a phone has
/// to clear the bell on a tablet too, which a local marker could not do.
///
/// Groups whose server predates the activity route contribute nothing rather than erroring
/// - the bell simply reflects the groups that can answer.

/// unreadActivity sums the unread counts of every group that can report one. Unreachable
/// groups count zero rather than failing the whole thing: a bell that disappears because
/// one of three servers is down is worse than a slightly low count.
Future<int> unreadActivity(WidgetRef ref) async {
  final groups = activityGroups(ref.read(multiSessionProvider));
  if (groups.isEmpty) return 0;
  final counts = await Future.wait<int>([
    for (final g in groups)
      ref
          .read(apiForGroupProvider(g.id))
          .activity(limit: 1)
          .then<int>((page) => page.unreadCount)
          .catchError((_) => 0),
  ]);
  return counts.fold<int>(0, (a, b) => a + b);
}

/// badgeLabel is what the dot reads. Past 99 the exact number stops being information and
/// starts being a number that does not fit, so it caps.
String badgeLabel(int count) => count > 99 ? '99+' : '$count';

class ActivityBell extends ConsumerStatefulWidget {
  const ActivityBell({super.key});

  @override
  ConsumerState<ActivityBell> createState() => _ActivityBellState();
}

class _ActivityBellState extends ConsumerState<ActivityBell> {
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final n = await unreadActivity(ref);
    if (mounted && n != _unread) setState(() => _unread = n);
  }

  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ActivityScreen()),
    );
    // Opening the list marks it seen on the server, so the count that comes back is zero -
    // read it rather than assuming, in case a group was unreachable and kept its own.
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing to show when no connected group can answer: an older self-hosted server has
    // no such route, and a bell that opens an empty list is worse than no bell.
    if (activityGroups(ref.watch(multiSessionProvider)).isEmpty) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: _unread > 0 ? 'Activity, ${badgeLabel(_unread)} new' : 'Activity',
      onPressed: _open,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications_none, color: kFgSecondary),
          if (_unread > 0)
            Positioned(
              right: -3,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 15),
                decoration: BoxDecoration(
                  color: kLike,
                  borderRadius: BorderRadius.circular(8),
                  // A ring in the bar's own colour, so the badge reads as sitting on top of
                  // the bell rather than merging into its outline.
                  border: Border.all(color: kBgMain, width: 1.5),
                ),
                child: Text(
                  badgeLabel(_unread),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700, height: 1.3),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

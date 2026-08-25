import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/user_avatar.dart';

/// Who you have blocked, and the way to undo it.
///
/// Blocking already worked, but only in one direction: the button lives on the other
/// person's profile, and blocking them takes their check-ins and comments out of every view
/// you have. So the way back to that button was to remember their name well enough to find
/// them in people search - which is not a route anyone would guess at, and not one you can
/// take at all if you blocked the wrong person and never knew their name.
///
/// Blocking is per server, because each group is its own server and its own block list. With
/// more than one group connected the rows say which group they belong to, the same way the
/// activity list does.

/// One blocked person, tagged with the group whose server holds that block.
typedef _Blocked = ({User user, ServerAccount group});

class BlockedPeopleScreen extends ConsumerStatefulWidget {
  const BlockedPeopleScreen({super.key});

  @override
  ConsumerState<BlockedPeopleScreen> createState() => _BlockedPeopleScreenState();
}

class _BlockedPeopleScreenState extends ConsumerState<BlockedPeopleScreen> {
  late Future<(List<_Blocked>, List<String>)> _future = _load();

  /// Ids currently being unblocked, so a row cannot be tapped twice while the request that
  /// removes it is still in the air.
  final _working = <String>{};

  String _key(_Blocked b) => '${b.group.id}:${b.user.id}';

  Future<(List<_Blocked>, List<String>)> _load() async {
    final groups = ref.read(multiSessionProvider).signedIn;
    if (groups.isEmpty) return (<_Blocked>[], <String>[]);

    final lists = await Future.wait([
      for (final g in groups)
        ref
            .read(apiForGroupProvider(g.id))
            .blockedUsers()
            .then<List<User>?>((us) => us)
            .catchError((_) => null),
    ]);

    final out = <_Blocked>[];
    final unreachable = <String>[];
    for (var i = 0; i < groups.length; i++) {
      final list = lists[i];
      if (list == null) {
        unreachable.add(groups[i].displayName);
        continue;
      }
      for (final u in list) {
        out.add((user: u, group: groups[i]));
      }
    }
    return (out, unreachable);
  }

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f.then((_) {}).catchError((_) {});
  }

  Future<void> _unblock(_Blocked b) async {
    final key = _key(b);
    if (_working.contains(key)) return;
    setState(() => _working.add(key));
    try {
      await ref.read(apiForGroupProvider(b.group.id)).unblockUser(b.user.id);
      if (!mounted) return;
      // Their check-ins come back the moment the block is gone, so the feed has to be
      // rebuilt rather than left showing a view that filtered them out.
      ref.invalidate(feedProvider);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${b.user.name} unblocked. Their check-ins will show again.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not unblock. Try again.')));
    } finally {
      if (mounted) setState(() => _working.remove(key));
    }
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
        title: const Text('Blocked people',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: FutureBuilder<(List<_Blocked>, List<String>)>(
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
                  const Text('Could not load your block list.',
                      style: TextStyle(color: kFgSecondary)),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _refresh, child: const Text('Try again')),
                ],
              ),
            );
          }
          final (people, unreachable) = snap.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
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
                if (people.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 64, 24, 24),
                    child: Center(
                      child: Text(
                        "You haven't blocked anyone.\n"
                        'You can block someone from their profile.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kFgMuted, height: 1.5),
                      ),
                    ),
                  )
                else
                  ...people.map((b) => _row(b, showGroup: multi)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(_Blocked b, {required bool showGroup}) {
    final busy = _working.contains(_key(b));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          UserAvatar(
            name: b.user.name,
            mediaId: b.user.profileMediaId,
            size: 40,
            colorSeed: b.user.id,
            groupId: b.group.id,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.user.name,
                    style: const TextStyle(
                        color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
                if (showGroup) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration:
                            BoxDecoration(color: b.group.displayColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(b.group.displayName,
                          style: const TextStyle(color: kFgMuted, fontSize: 11)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: busy ? null : () => _unblock(b),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: kBorder),
              foregroundColor: kFgSecondary,
              // Comfortably tappable rather than only as tall as its label.
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kFgSecondary),
                  )
                : const Text('Unblock'),
          ),
        ],
      ),
    );
  }
}

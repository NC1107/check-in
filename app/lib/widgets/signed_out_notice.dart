import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/onboarding/auth_screen.dart';
import '../state/app_state.dart';
import '../theme/accent.dart';
import '../theme/tokens.dart';

/// Tells the member which groups their session was rejected for, with a way back in. Sits at
/// the top of the feed; renders nothing when no group was signed out behind their back.
class SignedOutNotices extends ConsumerWidget {
  const SignedOutNotices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(signedOutNoticeGroupsProvider);
    if (groups.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [for (final g in groups) _SignedOutNotice(group: g)],
    );
  }
}

class _SignedOutNotice extends ConsumerWidget {
  const _SignedOutNotice({required this.group});

  final ServerAccount group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Container(
        padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4, right: 2),
        decoration: BoxDecoration(
          color: kBgSurface,
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 16, color: kFgMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'You were signed out of ${group.displayName}. '
                "You won't see its updates until you sign in again.",
                style: const TextStyle(color: kFgSecondary, fontSize: 12.5),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AuthScreen(initialServer: group.baseUrl),
                ),
              ),
              child: Text('Sign in', style: TextStyle(color: context.accent)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18, color: kFgMuted),
              tooltip: 'Dismiss',
              onPressed: () => ref.read(signOutNoticesProvider.notifier).clear(group.id),
            ),
          ],
        ),
      ),
    );
  }
}

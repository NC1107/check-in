import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/accent.dart';
import '../../theme/tokens.dart';

/// One curated "What's New" entry. [version] is an internal marker (not the store version,
/// which CI stamps) that we remember as "already seen" - bump it whenever you add an entry,
/// in the same release that ships the change it describes.
class ReleaseNote {
  const ReleaseNote({required this.version, required this.highlights});

  final String version;
  final List<String> highlights;
}

/// Curated release notes, newest first. Add an entry only when there's something members
/// should notice; the auto sheet shows everything newer than what they last acknowledged.
const releaseNotes = <ReleaseNote>[
  ReleaseNote(
    version: '1.1',
    highlights: [
      'Filter your feed by a custom date range - not just Today, this week, or this month.',
      'Download every photo matching a filter right from the search bar, with a quick confirm.',
      'Tap the top of the screen to jump back to the top of the feed.',
    ],
  ),
];

const _lastSeenKey = 'whats_new_last_seen_version';

/// The notes a member hasn't seen yet, given the [lastSeen] version they last acknowledged,
/// newest first. Empty on a fresh install (lastSeen null) so a changelog never greets a
/// brand-new user, and empty when nothing is newer.
List<ReleaseNote> unseenReleaseNotes(String? lastSeen) {
  if (releaseNotes.isEmpty || lastSeen == null) return const [];
  if (lastSeen == releaseNotes.first.version) return const [];
  final idx = releaseNotes.indexWhere((n) => n.version == lastSeen);
  // Unknown/older marker → everything is new; otherwise everything above it.
  return idx < 0 ? releaseNotes : releaseNotes.sublist(0, idx);
}

/// Shows the "What's New" sheet once after an update, then records the latest version so it
/// won't show again until the next release with notes. A fresh install is seeded silently
/// (no interruption); the sheet then appears on the first update after that.
Future<void> maybeShowWhatsNew(BuildContext context) async {
  if (releaseNotes.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final lastSeen = prefs.getString(_lastSeenKey);
  // Record "now current" up front so the sheet shows at most once, even if it's dismissed
  // by the app closing.
  await prefs.setString(_lastSeenKey, releaseNotes.first.version);
  final unseen = unseenReleaseNotes(lastSeen);
  if (unseen.isEmpty || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _WhatsNewSheet(notes: unseen),
  );
}

class _WhatsNewSheet extends StatelessWidget {
  const _WhatsNewSheet({required this.notes});

  final List<ReleaseNote> notes;

  @override
  Widget build(BuildContext context) {
    final highlights = [for (final n in notes) ...n.highlights];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration:
                    BoxDecoration(color: kBorder, borderRadius: BorderRadius.circular(9999)),
              ),
            ),
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 20, color: context.accent),
                const SizedBox(width: 9),
                const Text("What's New",
                    style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 19)),
              ],
            ),
            const SizedBox(height: 16),
            for (final h in highlights)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 6, right: 11),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: context.accent, shape: BoxShape.circle),
                    ),
                    Expanded(
                      child: Text(h,
                          style:
                              const TextStyle(color: kFgSecondary, fontSize: 14.5, height: 1.35)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  Navigator.of(context).pop();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: context.accent,
                  foregroundColor: context.onAccent,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

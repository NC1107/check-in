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
    version: '1.10',
    highlights: [
      'Tag people on a check-in shared to several groups - each group sees its own members tagged, and the picker notes who is not in which group.',
      'Tapping a playing clip now opens it full screen exactly in place - no restart, no stutter.',
    ],
  ),
  ReleaseNote(
    version: '1.9',
    highlights: [
      'Post video clips - record or pick a video, trim it down to ten seconds, and share it like a photo.',
      'Clips play right in your feed as you scroll, with sound following your ring/silent switch. Tap one to go full screen exactly where it left off.',
      'Invite someone with a link - it opens Check-In and fills in the group address for them. Hosts: find yours in the admin panel.',
      'Joining another group now fills in your name and photo from the account you already have.',
      "One check-in shared to several groups you're both in sends one notification now, not one per group.",
      'GIFs animate now instead of freezing on their first frame.',
      'Save any photo or video from a check-in to your camera roll.',
      'Tapping a photo flies it into full screen instead of fading.',
      'Joining a group no longer asks you to pick an app color again (or quietly changes the one you had).',
    ],
  ),
  ReleaseNote(
    version: '1.3',
    highlights: [
      'Share one check-in to several groups at once - it shows up as a single card, not a separate copy in each feed.',
      'Reply directly to a comment, and that person gets notified - not just whoever wrote the check-in.',
      "Sync your profile picture across every group you're in with one tap, instead of setting it separately in each one.",
      'Tapping your own check-in - even one shared to another group - now opens your real profile, with full settings.',
      'Swipe between every photo on a check-in in full screen, not just the one you tapped into.',
      'Wide and tall photos show at their own shape now instead of getting cropped into a square.',
      'Scrolling the combined feed all the way down keeps loading older check-ins, instead of stopping after the first page.',
      'Picking a place to filter by is now one dropdown instead of a long row of buttons.',
    ],
  ),
  ReleaseNote(
    version: '1.2',
    highlights: [
      'Get one daily summary of new check-ins instead of a notification for each - at a time you pick.',
      "A 'You're all caught up' line shows where the check-ins you've already seen begin.",
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
    // Capped well below full screen height (same technique as the feed's filter sheet) so
    // there's always room above for the status bar, and so "Got it" stays reachable without
    // scrolling past a long highlight list - only the list itself scrolls in the middle.
    final maxHeight = MediaQuery.of(context).size.height * 0.82;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
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
                      style:
                          TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 19)),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                                decoration:
                                    BoxDecoration(color: context.accent, shape: BoxShape.circle),
                              ),
                              Expanded(
                                child: Text(h,
                                    style: const TextStyle(
                                        color: kFgSecondary, fontSize: 14.5, height: 1.35)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
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
      ),
    );
  }
}

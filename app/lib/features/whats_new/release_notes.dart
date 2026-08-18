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
    version: '1.20',
    highlights: [
      "Places: every spot your group has checked in from, with how many of you have been there and everything you posted while you were.",
      'Android: photos taken on an Android phone can carry their location again. Android had been stripping it out before we ever saw it.',
    ],
  ),
  // One consolidated entry rather than the eleven that shipped to TestFlight between the
  // store's 1.5 and now: an App Store member last saw the 1.3 entry, so this is the whole
  // story of the update they are actually installing, and it is deliberately word for word
  // the same text as the App Store "What's New" so the two never tell different stories.
  ReleaseNote(
    version: '1.19.1',
    highlights: [
      'Video clips. Record or pick a video, trim it down to ten seconds, and post it like a photo. Clips play as you scroll, with sound following your ring/silent switch, and tapping one opens it full screen right where it left off.',
      "GIFs. There's a GIF button now when you write a check-in or a comment.",
      "Recaps. Your group gets a recap post covering the period: one swipeable deck opening on a cover made from that period's own photos, with the most-loved check-ins ranked behind it and everyone who posted included. Hosts choose weekly or monthly, or generate one any time from group settings. You also pick up a title on your profile from it, like Night Owl or Quiet Achiever.",
      "Memories. A place to look back through the group's history: a random old check-in, the trips and nights out you all posted from pulled back together into one place, your history month by month, and old photos nobody ever got round to liking. It isn't in the tab bar - have a look around the bottom of the feed.",
      'Smaller things: invite links that open straight into the app and fill in the group address, tagging people on a check-in shared to several groups, filtering the feed by more than one place at once, saving any photo or clip to your camera roll, replying to a comment so that person gets notified, and one notification instead of three when a check-in is shared to groups you are both in.',
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
  // A marker we no longer recognise means the member has used the app before but their
  // marker predates the list - entries get consolidated when one store release bundles
  // several internal ones. Re-announcing the whole history to them would surface things
  // they read long ago, so show only what actually just changed.
  return idx < 0 ? releaseNotes.take(1).toList() : releaseNotes.sublist(0, idx);
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

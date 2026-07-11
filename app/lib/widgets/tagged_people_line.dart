import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../features/profile/profile_screen.dart';
import '../theme/tokens.dart';
import 'user_avatar.dart';

/// The "with Alice, Bob & 3 others" line under a check-in's author, with each name tappable
/// to open that member's profile. When the list is collapsed to "& N others", tapping it
/// opens a sheet of everyone tagged. Rendered as spans (not widgets) so it still truncates
/// to one line cleanly; the tap recognizers are owned here and disposed with the widget.
class TaggedPeopleLine extends StatefulWidget {
  const TaggedPeopleLine({
    super.key,
    required this.people,
    required this.style,
    this.groupId,
  });

  final List<({int id, String name})> people;

  /// Base (muted) style for the line; names are rendered in the same colour, semibold.
  final TextStyle style;

  /// The connected group the members belong to (null = the current group).
  final String? groupId;

  @override
  State<TaggedPeopleLine> createState() => _TaggedPeopleLineState();
}

class _TaggedPeopleLineState extends State<TaggedPeopleLine> {
  final _recognizers = <TapGestureRecognizer>[];
  late TextSpan _span;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(TaggedPeopleLine old) {
    super.didUpdateWidget(old);
    if (old.people != widget.people || old.groupId != widget.groupId || old.style != widget.style) {
      _rebuild();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _rec(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(r);
    return r;
  }

  void _openProfile(int userId) {
    if (userId <= 0) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProfileScreen(userId: userId, groupId: widget.groupId),
    ));
  }

  void _showAll() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text('Checked in with',
                  style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in widget.people)
                    ListTile(
                      leading: UserAvatar(
                          name: p.name, size: 38, colorSeed: p.id, groupId: widget.groupId),
                      title: Text(p.name, style: const TextStyle(color: kFgPrimary, fontSize: 15)),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _openProfile(p.id);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _rebuild() {
    _disposeRecognizers();
    final people = widget.people;
    final base = widget.style;
    final link = base.copyWith(fontWeight: FontWeight.w600);

    TextSpan name(({int id, String name}) p) =>
        TextSpan(text: p.name, style: link, recognizer: _rec(() => _openProfile(p.id)));

    final children = <InlineSpan>[TextSpan(text: 'with ', style: base)];
    if (people.length == 1) {
      children.add(name(people[0]));
    } else if (people.length == 2) {
      children
        ..add(name(people[0]))
        ..add(TextSpan(text: ' & ', style: base))
        ..add(name(people[1]));
    } else if (people.length > 2) {
      children
        ..add(name(people[0]))
        ..add(TextSpan(text: ', ', style: base))
        ..add(name(people[1]))
        ..add(TextSpan(text: ' & ', style: base))
        ..add(TextSpan(
          text: '${people.length - 2} others',
          style: link,
          recognizer: _rec(_showAll),
        ));
    }
    _span = TextSpan(children: children);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.people.isEmpty) return const SizedBox.shrink();
    return Text.rich(_span, maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style);
  }
}

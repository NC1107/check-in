import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Reasons offered in the report sheet, shared between check-ins and comments.
const kReportReasons = [
  'Inappropriate or offensive content',
  'Harassment or bullying',
  'Spam',
  'False information',
  'Other',
];

/// Bottom sheet letting the user pick a reason before submitting a report. Pops the
/// selected reason string, or null when dismissed. [subject] names what's being reported
/// ("check-in", "comment") in the sheet's title.
class ReportSheet extends StatelessWidget {
  const ReportSheet({super.key, required this.subject});

  final String subject;

  @override
  Widget build(BuildContext context) {
    // ListView rather than a plain Column: on a short screen or with a large text scale,
    // the header plus five reasons can exceed the modal's max height. shrinkWrap sizes the
    // sheet to its content as before when it fits, and scrolls instead of overflowing when
    // it doesn't - a reason can otherwise be pushed below the visible sheet with no way to
    // reach it.
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        const SizedBox(height: 10),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(color: kBorder, borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Report this $subject',
                style:
                    const TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('The host will review your report within 24 hours.',
                style: TextStyle(color: kFgMuted, fontSize: 13)),
          ),
        ),
        const Divider(color: kBorder, height: 1),
        ...kReportReasons.map(
          (r) => ListTile(
            title: Text(r, style: const TextStyle(color: kFgPrimary, fontSize: 15)),
            // No chevron: tapping a reason submits the report, it doesn't drill in.
            onTap: () => Navigator.of(context).pop(r),
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
      ],
    );
  }
}

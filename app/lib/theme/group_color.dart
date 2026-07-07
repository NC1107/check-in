import 'package:flutter/material.dart';

/// A curated palette of admin-selectable group colors, deliberately distinct from the
/// personal accent presets (theme/accent.dart) and from one another. Group color is an
/// identity/attribution cue only - a card's left rail and a dot by the group in the merged
/// feed - never an action color, so the feed never turns into a rainbow of buttons. These
/// ids must stay in sync with the server's groupColorIDs (internal/api/auth_handlers.go).
class GroupColor {
  const GroupColor(this.id, this.name, this.color);
  final String id;
  final String name;
  final Color color;
}

const kGroupColors = <GroupColor>[
  GroupColor('coral', 'Coral', Color(0xFFFF7A66)),
  GroupColor('gold', 'Gold', Color(0xFFE5B93C)),
  GroupColor('lime', 'Lime', Color(0xFF93D845)),
  GroupColor('cyan', 'Cyan', Color(0xFF34C6D8)),
  GroupColor('indigo', 'Indigo', Color(0xFF7C83FF)),
  GroupColor('magenta', 'Magenta', Color(0xFFE668C8)),
  GroupColor('orange', 'Orange', Color(0xFFF58A3C)),
  GroupColor('steel', 'Steel', Color(0xFF8FA0B5)),
];

/// The color for an admin-set palette id, or null when the id is empty/unknown.
Color? groupColorById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final g in kGroupColors) {
    if (g.id == id) return g.color;
  }
  return null;
}

/// A deterministic color for a group with no admin-set color, derived from its id so every
/// member sees the same one and groups are still told apart before anyone customizes.
Color groupColorFor(String groupId) {
  var hash = 0;
  for (final code in groupId.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  return kGroupColors[hash % kGroupColors.length].color;
}

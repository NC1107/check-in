import 'package:flutter/material.dart';

import 'auth_image.dart';

const _avatarPalette = [
  Color(0xFF5557E0),
  Color(0xFF13AF9D),
  Color(0xFFDD1C85),
  Color(0xFFE9960A),
  Color(0xFF8458E9),
  Color(0xFF22C55E),
  Color(0xFFEF4444),
  Color(0xFF3B82F6),
];

/// A stable, pleasant color for an initial avatar, seeded by a user id (or name hash).
Color avatarColor(int seed) => _avatarPalette[seed.abs() % _avatarPalette.length];

/// The single avatar widget used across the app: the user's profile photo when they have
/// one, otherwise their initial on a consistent color.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    required this.size,
    this.mediaId,
    this.colorSeed,
    this.groupId,
    this.semanticLabel,
  });

  final String name;
  final double size;
  final int? mediaId;

  /// Seeds the initial's background color (typically the user id). Falls back to the
  /// name's hash so the same person keeps the same color.
  final int? colorSeed;

  /// The connected group the photo's media id belongs to (null = the current group).
  final String? groupId;

  /// What a screen reader should announce, for an avatar that is itself tappable - the
  /// person's name, since what the tap does is open their profile.
  ///
  /// Null, the usual case, means decorative: the name is shown beside the avatar everywhere
  /// it appears, so announcing anything here only repeats it. Either way the initial itself
  /// is never announced - a bare "S" tells nobody anything, and it is a generated colour
  /// underneath rather than text anyone chose, so judging it as text is wrong twice over.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: semanticLabel != null,
      excludeSemantics: true,
      child: mediaId != null ? _photo() : _initial(),
    );
  }

  Widget _photo() => ClipOval(
        child: SizedBox(
            width: size, height: size, child: AuthImage(mediaId: mediaId!, groupId: groupId)),
      );

  Widget _initial() => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: avatarColor(colorSeed ?? name.hashCode),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: size * 0.4,
            height: 1,
          ),
        ),
      );
}

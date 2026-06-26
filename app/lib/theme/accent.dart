import 'package:flutter/material.dart';

/// A selectable accent palette. The base accent always carries near-black text
/// (onAccent) for legibility; hover/light are derived for buttons and tints.
///
/// Carried on the app's [ThemeData] as a [ThemeExtension] so any widget can read
/// the current accent via `context.accent` without plumbing a provider everywhere.
@immutable
class AccentPalette extends ThemeExtension<AccentPalette> {
  const AccentPalette({
    required this.id,
    required this.name,
    required this.base,
    required this.hover,
    required this.light,
    required this.onAccent,
  });

  final String id;
  final String name;
  final Color base;
  final Color hover; // slightly lighter, for pressed/hover states
  final Color light; // ~16% alpha tint, for connectors/badges
  final Color onAccent; // text/icons on top of the accent

  /// Derive hover/light/onAccent from a single bright base color.
  factory AccentPalette.from(String id, String name, Color base) {
    return AccentPalette(
      id: id,
      name: name,
      base: base,
      hover: Color.lerp(base, Colors.white, 0.18)!,
      light: base.withValues(alpha: 0.16),
      onAccent: const Color(0xFF07140C), // near-black; all presets are bright enough
    );
  }

  @override
  AccentPalette copyWith({Color? base, Color? hover, Color? light, Color? onAccent}) {
    return AccentPalette(
      id: id,
      name: name,
      base: base ?? this.base,
      hover: hover ?? this.hover,
      light: light ?? this.light,
      onAccent: onAccent ?? this.onAccent,
    );
  }

  @override
  AccentPalette lerp(ThemeExtension<AccentPalette>? other, double t) {
    if (other is! AccentPalette) return this;
    return AccentPalette(
      id: t < 0.5 ? id : other.id,
      name: t < 0.5 ? name : other.name,
      base: Color.lerp(base, other.base, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
      light: Color.lerp(light, other.light, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
    );
  }
}

/// Curated, tasteful accent presets. The first (green) is the original default.
final List<AccentPalette> kAccentPresets = [
  AccentPalette.from('green', 'Onyx Green', const Color(0xFF37E07E)),
  AccentPalette.from('sky', 'Sky', const Color(0xFF3B9EFF)),
  AccentPalette.from('violet', 'Violet', const Color(0xFF9B7CFF)),
  AccentPalette.from('amber', 'Amber', const Color(0xFFF5B83D)),
  AccentPalette.from('rose', 'Rose', const Color(0xFFFF6F91)),
  AccentPalette.from('teal', 'Teal', const Color(0xFF2DD4BF)),
];

/// Look up a preset by id, falling back to the default green.
AccentPalette accentById(String? id) =>
    kAccentPresets.firstWhere((p) => p.id == id, orElse: () => kAccentPresets.first);

/// `context.accent` and friends — resolve the live accent from the theme.
extension AccentContext on BuildContext {
  AccentPalette get accentPalette =>
      Theme.of(this).extension<AccentPalette>() ?? kAccentPresets.first;
  Color get accent => accentPalette.base;
  Color get accentHover => accentPalette.hover;
  Color get accentLight => accentPalette.light;
  Color get onAccent => accentPalette.onAccent;
}

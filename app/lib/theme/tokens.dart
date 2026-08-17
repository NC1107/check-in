import 'package:flutter/material.dart';

/// Central color tokens for the Check-In dark theme. Every screen aliases these, so
/// changing the palette means editing this one file.
///
/// "Onyx" - a simple near-black + greys theme with a single popping green accent (used
/// for buttons, links, and the timeline connector nodes). The accent is bright, so text
/// on it (kOnAccent) is near-black for legibility.

// Backgrounds & surfaces (near-black canvas → grey cards → hover).
const kBgMain = Color(0xFF0A0A0A);
const kBgSurface = Color(0xFF161616);
const kBgSurfaceHover = Color(0xFF1F1F1F);
const kBorder = Color(0xFF2A2A2A);

// Text hierarchy (neutral greys). kFgMuted is lifted to clear WCAG AA (~5.4:1 on the
// surface cards) since it carries a lot of small body text: timestamps, hints, helper
// lines, empty-state copy.
const kFgPrimary = Color(0xFFF4F4F5);
const kFgSecondary = Color(0xFFA1A1AA);
const kFgMuted = Color(0xFF8B8B93);

// Accent - a vivid green that pops on the black/grey base. Bright, so text on it is dark.
const kAccent = Color(0xFF37E07E);
const kAccentHover = Color(0xFF5CE89A);
const kAccentLight = Color(0x2937E07E); // ~16% alpha, for tints/connectors
const kOnAccent = Color(0xFF07140C); // near-black text/icons on the green accent

// Semantic.
const kLike = Color(0xFFF2557B); // danger / like (rose-red, pops on black, distinct from green)
const kSuccess = Color(0xFF37E07E); // online / success (matches the accent green)

// Bottom nav shape - shared by home_shell.dart's _NavItem and the hidden Memories handle
// (memories_screen.dart), so the handle's pill can mirror this exact icon+gap+label shape
// and land its own center on the same line the Feed/You icon glyphs sit on. A Column
// centered with `mainAxisAlignment.center` puts its first child's own center at
// `boxCenter - (restOfBlockHeight)/2` regardless of that first child's own height - so
// reusing the identical trailing gap+label-sized block after the pill (see MemoriesHandle's
// build()) lands the pill on the icons' own optical center even though the pill (26pt tall)
// and an icon glyph (23pt) aren't the same height.
const kBottomNavIconSize = 23.0;
const kBottomNavIconLabelGap = 3.0;
const kBottomNavLabelStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w600);

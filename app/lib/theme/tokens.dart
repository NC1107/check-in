import 'package:flutter/material.dart';

/// Central color tokens for the Check-In dark theme. Every screen aliases these, so
/// changing the palette means editing this one file.
///
/// "Amethyst" — built around the user's deep violet ramp (#3A015C → #11001C). The ramp
/// supplies the backgrounds/surfaces; text, accent, and semantic colors are tuned to it
/// for contrast (WCAG AA) and a cohesive, premium feel.

// Backgrounds & surfaces (darkest canvas → lifted cards → hover).
const kBgMain = Color(0xFF11001C); // user's midnight-violet-2
const kBgSurface = Color(0xFF1E0233); // cards
const kBgSurfaceHover = Color(0xFF2A044A);
const kBorder = Color(0xFF3A105C); // visible amethyst hairline

// Text hierarchy (violet-tinted neutrals).
const kFgPrimary = Color(0xFFF3EAFB);
const kFgSecondary = Color(0xFFC2ADD6);
const kFgMuted = Color(0xFF8C77A6);

// Accent — a rich violet that pops on the deep base; white reads AA on it.
const kAccent = Color(0xFF7C3AED);
const kAccentHover = Color(0xFF9061F0);
const kAccentLight = Color(0x297C3AED); // ~16% alpha, for tints/connectors
const kOnAccent = Colors.white;

// Semantic.
const kLike = Color(0xFFF2587A); // danger / like (rose-red, harmonizes with violet)
const kSuccess = Color(0xFF4ED9A6); // online / success (mint)

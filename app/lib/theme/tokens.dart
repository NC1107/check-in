import 'package:flutter/material.dart';

/// Central color tokens for the Check-In dark theme. Every screen aliases these, so
/// changing the palette means editing this one file.
///
/// "Onyx" — a simple near-black + greys theme with a single popping green accent (used
/// for buttons, links, and the timeline connector nodes). The accent is bright, so text
/// on it (kOnAccent) is near-black for legibility.

// Backgrounds & surfaces (near-black canvas → grey cards → hover).
const kBgMain = Color(0xFF0A0A0A);
const kBgSurface = Color(0xFF161616);
const kBgSurfaceHover = Color(0xFF1F1F1F);
const kBorder = Color(0xFF2A2A2A);

// Text hierarchy (neutral greys).
const kFgPrimary = Color(0xFFF4F4F5);
const kFgSecondary = Color(0xFFA1A1AA);
const kFgMuted = Color(0xFF6B6B72);

// Accent — a vivid green that pops on the black/grey base. Bright, so text on it is dark.
const kAccent = Color(0xFF37E07E);
const kAccentHover = Color(0xFF5CE89A);
const kAccentLight = Color(0x2937E07E); // ~16% alpha, for tints/connectors
const kOnAccent = Color(0xFF07140C); // near-black text/icons on the green accent

// Semantic.
const kLike = Color(0xFFF2557B); // danger / like (rose-red, pops on black, distinct from green)
const kSuccess = Color(0xFF37E07E); // online / success (matches the accent green)

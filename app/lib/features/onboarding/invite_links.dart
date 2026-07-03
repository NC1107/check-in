import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Invite-link plumbing. A group's invite is a URL that identifies its server:
///
///     https://GROUP_DOMAIN/join                        (universal / app link)
///     checkin://join?server=https%3A%2F%2FGROUP_DOMAIN (custom-scheme fallback,
///                                                       used by the /join web page)
///
/// Membership is still gated by the group's phone allowlist — the link only tells the
/// app which server to talk to.

/// Extracts the group server base URL from an invite link, or null when the URI isn't
/// an invite.
String? inviteServerFromUri(Uri uri) {
  if (uri.scheme == 'checkin' && uri.host == 'join') {
    final server = uri.queryParameters['server'];
    if (server == null || server.isEmpty) return null;
    final parsed = Uri.tryParse(server);
    if (parsed == null || parsed.host.isEmpty) return null;
    return server;
  }
  if ((uri.scheme == 'https' || uri.scheme == 'http') && uri.path == '/join') {
    if (uri.host.isEmpty) return null;
    final defaultPort =
        (uri.scheme == 'https' && uri.port == 443) || (uri.scheme == 'http' && uri.port == 80);
    final port = uri.hasPort && !defaultPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }
  return null;
}

/// An invite that arrived before the app could route it (EULA not yet accepted, or a
/// cold start straight from the link). The auth screen picks it up as its prefill.
final pendingInviteServerProvider = StateProvider<String?>((ref) => null);

import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/onboarding/invite_links.dart';

/// Invite links carry the group's server address in two shapes: the group's own
/// `https://<domain>/join` page (universal/app link) and the checkin:// fallback that
/// page offers. Anything else must be ignored.
void main() {
  test('parses the https /join universal link into the server base URL', () {
    expect(
      inviteServerFromUri(Uri.parse('https://alpha.check-in.example.com/join')),
      'https://alpha.check-in.example.com',
    );
    expect(
      inviteServerFromUri(Uri.parse('https://host.example.com:8443/join')),
      'https://host.example.com:8443',
    );
  });

  test('parses the checkin:// fallback with an encoded server parameter', () {
    expect(
      inviteServerFromUri(Uri.parse('checkin://join?server=https%3A%2F%2Falpha.example.com')),
      'https://alpha.example.com',
    );
  });

  test('rejects non-invite URIs', () {
    expect(inviteServerFromUri(Uri.parse('https://alpha.example.com/other')), isNull);
    expect(inviteServerFromUri(Uri.parse('checkin://join')), isNull);
    expect(inviteServerFromUri(Uri.parse('checkin://join?server=')), isNull);
    expect(inviteServerFromUri(Uri.parse('checkin://other?server=https%3A%2F%2Fx.com')), isNull);
    expect(inviteServerFromUri(Uri.parse('mailto:a@b.c')), isNull);
  });
}

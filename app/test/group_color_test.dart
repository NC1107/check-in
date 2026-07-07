import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/state/app_state.dart';
import 'package:checkin/theme/group_color.dart';

/// Group colors: the admin-set palette lookup, the deterministic fallback, and how
/// ServerAccount picks between them. These must stay in sync with the server's
/// groupColorIDs (validated in servername_test.go).
void main() {
  test('groupColorById returns the palette color for a known id, null otherwise', () {
    expect(groupColorById('coral'), kGroupColors.firstWhere((g) => g.id == 'coral').color);
    expect(groupColorById(''), isNull);
    expect(groupColorById(null), isNull);
    expect(groupColorById('chartreuse'), isNull);
  });

  test('groupColorFor is deterministic and always lands in the palette', () {
    final palette = {for (final g in kGroupColors) g.color};
    expect(groupColorFor('alpha.invalid'), groupColorFor('alpha.invalid')); // stable
    expect(palette.contains(groupColorFor('alpha.invalid')), isTrue);
    expect(palette.contains(groupColorFor('beta.invalid')), isTrue);
  });

  test('displayColor prefers the admin color, else the deterministic one, never null', () {
    const admin = ServerAccount(
        id: 'a.invalid', baseUrl: 'https://a.invalid', serverName: 'A', color: 'indigo');
    expect(admin.displayColor, groupColorById('indigo'));

    const auto = ServerAccount(id: 'a.invalid', baseUrl: 'https://a.invalid', serverName: 'A');
    expect(auto.displayColor, groupColorFor('a.invalid'));

    // A stale/unknown id falls back to the deterministic color, not null.
    const stale = ServerAccount(
        id: 'a.invalid', baseUrl: 'https://a.invalid', serverName: 'A', color: 'ancient');
    expect(stale.displayColor, groupColorFor('a.invalid'));
  });
}

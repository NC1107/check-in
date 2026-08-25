import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/features/onboarding/phone_field.dart';

/// The server stores phone numbers as bare digits with the country code and no "+", so
/// anywhere one was shown verbatim - the host's member list, the invite list - it arrived
/// as an unbroken run like "15550000002". Unreadable, and impossible to match against a
/// contact at a glance, which is the only reason a host looks at that list.
void main() {
  test('groups a +1 number the way the input field does', () {
    expect(formatStoredPhone('15550000002'), '+1 (555) 000-0002');
    expect(formatStoredPhone('14155550148'), '+1 (415) 555-0148');
  });

  test('accepts a number that already carries its plus', () {
    expect(formatStoredPhone('+15550000002'), '+1 (555) 000-0002');
  });

  // Guessing a national grouping for a country whose convention we do not know would
  // present the number wrongly rather than plainly - the same rule PhoneNumberFormatter
  // follows for input.
  test('leaves other countries ungrouped, but adds the plus', () {
    expect(formatStoredPhone('447700900123'), '+447700900123');
    expect(formatStoredPhone('351912345678'), '+351912345678');
  });

  test('an 11-digit number not starting with 1 is not treated as +1', () {
    expect(formatStoredPhone('44770090012'), '+44770090012');
  });

  // A stored value that is not a number at all must come back as-is rather than as a bare
  // "+", which would look like a bug in the list rather than bad data behind it.
  test('a blank or non-numeric value is passed through untouched', () {
    expect(formatStoredPhone(''), '');
    expect(formatStoredPhone('unknown'), 'unknown');
  });

  test('a short number keeps its digits', () {
    expect(formatStoredPhone('5550002'), '+5550002');
  });
}

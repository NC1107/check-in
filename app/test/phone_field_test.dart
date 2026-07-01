import 'package:checkin/features/onboarding/phone_field.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds [chars] through the formatter one keystroke at a time, inserting each
/// character at the current caret exactly as the platform would. This is the
/// path that used to drop a digit; the formatter must preserve every one.
TextEditingValue _type(PhoneNumberFormatter f, String chars) {
  var value = TextEditingValue.empty;
  for (final ch in chars.split('')) {
    final caret = value.selection.baseOffset < 0 ? value.text.length : value.selection.baseOffset;
    final proposed = TextEditingValue(
      text: value.text.substring(0, caret) + ch + value.text.substring(caret),
      selection: TextSelection.collapsed(offset: caret + 1),
    );
    value = f.formatEditUpdate(value, proposed);
  }
  return value;
}

String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');

void main() {
  group('PhoneNumberFormatter (US)', () {
    final f = PhoneNumberFormatter(kDefaultCountry);

    TextEditingValue paste(String text) => f.formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)),
        );

    test('typing 10 digits groups them and keeps every digit', () {
      final v = _type(f, '2025550186');
      expect(v.text, '(202) 555-0186');
      expect(_digits(v.text), '2025550186');
      expect(v.selection.baseOffset, v.text.length);
    });

    test('never keeps more than 10 digits', () {
      final v = _type(f, '20255501869999');
      expect(_digits(v.text), '2025550186');
    });

    test('pasting the whole number formats it without loss', () {
      final v = paste('2025550186');
      expect(v.text, '(202) 555-0186');
      expect(_digits(v.text), '2025550186');
    });

    test('pasting/autofilling a number with the +1 country code strips it', () {
      expect(paste('+12025550186').text, '(202) 555-0186');
      expect(paste('12025550186').text, '(202) 555-0186');
      expect(paste('+1 (202) 555-0186').text, '(202) 555-0186');
    });

    test('inserting a digit in the middle preserves all digits (no drop)', () {
      var v = _type(f, '202555018'); // 9 digits so far
      v = f.formatEditUpdate(
        v,
        TextEditingValue(
          text: '9${v.text}', // insert a digit at the very front
          selection: const TextSelection.collapsed(offset: 1),
        ),
      );
      expect(_digits(v.text), '9202555018');
      expect(_digits(v.text).length, 10);
      expect(v.text, '(920) 255-5018');
    });
  });

  group('PhoneNumberFormatter (non-US)', () {
    final uk = kCountries.firstWhere((c) => c.name == 'United Kingdom');
    final f = PhoneNumberFormatter(uk);

    test('keeps other countries as plain digits (no US grouping)', () {
      final v = _type(f, '2071838750');
      expect(v.text, '2071838750');
    });

    test('strips a pasted country code for the selected country', () {
      final v = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: '+442071838750',
          selection: TextSelection.collapsed(offset: 13),
        ),
      );
      expect(v.text, '2071838750');
    });
  });

  group('splitE164', () {
    test('US number splits to +1 and the national digits', () {
      final r = splitE164('+12025550186');
      expect(r.country.dialCode, '1');
      expect(r.country.name, 'United States');
      expect(r.national, '2025550186');
    });

    test('prefers the longest matching dial code', () {
      final r = splitE164('+353861234567'); // Ireland, not "+3"/"+35"
      expect(r.country.dialCode, '353');
      expect(r.national, '861234567');
    });

    test('UK number splits correctly', () {
      final r = splitE164('+442071838750');
      expect(r.country.dialCode, '44');
      expect(r.national, '2071838750');
    });

    test('empty input falls back to the default country', () {
      final r = splitE164('');
      expect(r.country, kDefaultCountry);
      expect(r.national, '');
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/accent.dart';
import '../../theme/tokens.dart';

/// A dialable country: the flag, English name, dial code (no '+'), and the
/// acceptable national-number length so we can reject numbers that are too
/// short or too long before hitting the server.
class Country {
  const Country(this.flag, this.name, this.dialCode, {this.minLen = 6, this.maxLen = 15});

  final String flag;
  final String name;
  final String dialCode;
  final int minLen;
  final int maxLen;
}

/// Default to the US: it's the common case and matches the "+1" the server
/// prepends to bare 10-digit numbers.
const kDefaultCountry = Country('🇺🇸', 'United States', '1', minLen: 10, maxLen: 10);

/// A curated list of dial codes. US/Canada first (both +1, 10 digits), then a
/// broad set so international members and app reviewers can pick their region.
const kCountries = <Country>[
  kDefaultCountry,
  Country('🇨🇦', 'Canada', '1', minLen: 10, maxLen: 10),
  Country('🇬🇧', 'United Kingdom', '44', minLen: 9, maxLen: 10),
  Country('🇮🇪', 'Ireland', '353', minLen: 7, maxLen: 9),
  Country('🇦🇺', 'Australia', '61', minLen: 9, maxLen: 9),
  Country('🇳🇿', 'New Zealand', '64', minLen: 8, maxLen: 10),
  Country('🇩🇪', 'Germany', '49', minLen: 6, maxLen: 11),
  Country('🇫🇷', 'France', '33', minLen: 9, maxLen: 9),
  Country('🇪🇸', 'Spain', '34', minLen: 9, maxLen: 9),
  Country('🇮🇹', 'Italy', '39', minLen: 9, maxLen: 10),
  Country('🇳🇱', 'Netherlands', '31', minLen: 9, maxLen: 9),
  Country('🇧🇪', 'Belgium', '32', minLen: 8, maxLen: 9),
  Country('🇨🇭', 'Switzerland', '41', minLen: 9, maxLen: 9),
  Country('🇦🇹', 'Austria', '43', minLen: 7, maxLen: 13),
  Country('🇸🇪', 'Sweden', '46', minLen: 7, maxLen: 9),
  Country('🇳🇴', 'Norway', '47', minLen: 8, maxLen: 8),
  Country('🇩🇰', 'Denmark', '45', minLen: 8, maxLen: 8),
  Country('🇫🇮', 'Finland', '358', minLen: 6, maxLen: 10),
  Country('🇵🇱', 'Poland', '48', minLen: 9, maxLen: 9),
  Country('🇵🇹', 'Portugal', '351', minLen: 9, maxLen: 9),
  Country('🇬🇷', 'Greece', '30', minLen: 10, maxLen: 10),
  Country('🇨🇿', 'Czechia', '420', minLen: 9, maxLen: 9),
  Country('🇷🇴', 'Romania', '40', minLen: 9, maxLen: 9),
  Country('🇭🇺', 'Hungary', '36', minLen: 8, maxLen: 9),
  Country('🇲🇽', 'Mexico', '52', minLen: 10, maxLen: 10),
  Country('🇧🇷', 'Brazil', '55', minLen: 10, maxLen: 11),
  Country('🇦🇷', 'Argentina', '54', minLen: 10, maxLen: 11),
  Country('🇨🇱', 'Chile', '56', minLen: 9, maxLen: 9),
  Country('🇨🇴', 'Colombia', '57', minLen: 10, maxLen: 10),
  Country('🇮🇳', 'India', '91', minLen: 10, maxLen: 10),
  Country('🇨🇳', 'China', '86', minLen: 11, maxLen: 11),
  Country('🇯🇵', 'Japan', '81', minLen: 9, maxLen: 10),
  Country('🇰🇷', 'South Korea', '82', minLen: 9, maxLen: 10),
  Country('🇸🇬', 'Singapore', '65', minLen: 8, maxLen: 8),
  Country('🇭🇰', 'Hong Kong', '852', minLen: 8, maxLen: 8),
  Country('🇵🇭', 'Philippines', '63', minLen: 10, maxLen: 10),
  Country('🇮🇩', 'Indonesia', '62', minLen: 9, maxLen: 12),
  Country('🇲🇾', 'Malaysia', '60', minLen: 8, maxLen: 10),
  Country('🇹🇭', 'Thailand', '66', minLen: 9, maxLen: 9),
  Country('🇻🇳', 'Vietnam', '84', minLen: 9, maxLen: 10),
  Country('🇦🇪', 'United Arab Emirates', '971', minLen: 8, maxLen: 9),
  Country('🇸🇦', 'Saudi Arabia', '966', minLen: 9, maxLen: 9),
  Country('🇮🇱', 'Israel', '972', minLen: 8, maxLen: 9),
  Country('🇹🇷', 'Türkiye', '90', minLen: 10, maxLen: 10),
  Country('🇿🇦', 'South Africa', '27', minLen: 9, maxLen: 9),
  Country('🇳🇬', 'Nigeria', '234', minLen: 8, maxLen: 10),
  Country('🇰🇪', 'Kenya', '254', minLen: 9, maxLen: 9),
  Country('🇪🇬', 'Egypt', '20', minLen: 9, maxLen: 10),
  Country('🇷🇺', 'Russia', '7', minLen: 10, maxLen: 10),
  Country('🇺🇦', 'Ukraine', '380', minLen: 9, maxLen: 9),
];

/// Splits a stored "+[dialCode][national]" number back into a country and the
/// national digits, for prefilling the field. Prefers the longest matching dial
/// code and falls back to the default country when nothing matches.
({Country country, String national}) splitE164(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  Country? best;
  for (final c in kCountries) {
    if (digits.startsWith(c.dialCode) &&
        (best == null || c.dialCode.length > best.dialCode.length)) {
      best = c;
    }
  }
  final country = best ?? kDefaultCountry;
  final national =
      digits.startsWith(country.dialCode) ? digits.substring(country.dialCode.length) : digits;
  return (country: country, national: national);
}

/// A phone entry with a country-code selector on the left and the national
/// number on the right. The national number is stored digits-only in
/// [controller]; the caller prepends "+[dialCode]" when talking to the server.
class PhoneField extends StatelessWidget {
  const PhoneField({
    super.key,
    required this.controller,
    required this.country,
    required this.onCountryChanged,
    this.onChanged,
    this.errorText,
  });

  final TextEditingController controller;
  final Country country;
  final ValueChanged<Country> onCountryChanged;
  final ValueChanged<String>? onChanged;
  final String? errorText;

  List<TextInputFormatter> get _formatters => [PhoneNumberFormatter(country)];

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    final box = Container(
      decoration: BoxDecoration(
        color: kBgSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: hasError ? kLike : kBorder),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () => _openPicker(context),
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(country.flag, style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 6),
                  Text('+${country.dialCode}',
                      style: const TextStyle(color: kFgPrimary, fontSize: 15)),
                  const Icon(Icons.arrow_drop_down, color: kFgMuted, size: 20),
                ],
              ),
            ),
          ),
          Container(width: 1, height: 26, color: kBorder),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              // Offer the device's own number in the QuickType bar. If it arrives
              // with a country code, the formatter strips it (see below).
              autofillHints: const [AutofillHints.telephoneNumber],
              inputFormatters: _formatters,
              onChanged: onChanged,
              style: const TextStyle(color: kFgPrimary, fontSize: 15),
              cursorColor: context.accent,
              decoration: InputDecoration(
                hintText: country.dialCode == '1' ? '(415) 555-0148' : 'Phone number',
                hintStyle: const TextStyle(color: kFgMuted),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
              ),
            ),
          ),
        ],
      ),
    );
    if (!hasError) return box;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        box,
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 14, color: kLike),
              const SizedBox(width: 5),
              Expanded(
                child: Text(errorText!,
                    style: const TextStyle(color: kLike, fontSize: 12, height: 1.3)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    FocusScope.of(context).unfocus();
    final picked = await showModalBottomSheet<Country>(
      context: context,
      backgroundColor: kBgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const _CountryPickerSheet(),
    );
    if (picked != null) onCountryChanged(picked);
  }
}

class _CountryPickerSheet extends StatefulWidget {
  const _CountryPickerSheet();

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final code = q.replaceAll('+', '');
    final items = kCountries
        .where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || c.dialCode.contains(code))
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: kBorder, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: kFgPrimary),
                cursorColor: context.accent,
                decoration: InputDecoration(
                  hintText: 'Search country or code',
                  hintStyle: const TextStyle(color: kFgMuted),
                  prefixIcon: const Icon(Icons.search, color: kFgMuted),
                  filled: true,
                  fillColor: kBgMain,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final c = items[i];
                  return ListTile(
                    leading: Text(c.flag, style: const TextStyle(fontSize: 22)),
                    title: Text(c.name, style: const TextStyle(color: kFgPrimary, fontSize: 15)),
                    trailing: Text('+${c.dialCode}',
                        style: const TextStyle(color: kFgSecondary, fontSize: 15)),
                    onTap: () => Navigator.of(context).pop(c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps the national number clean for its [country]: digits only, capped to the
/// country's max length, +1 numbers grouped as "(415) 555-0148". A pasted or
/// autofilled number that still carries the country code has it stripped.
///
/// Unlike a naive mask it tracks the caret by the number of digits before it, so
/// fast typing can't desync and drop a digit (the bug that broke App Review).
class PhoneNumberFormatter extends TextInputFormatter {
  PhoneNumberFormatter(this.country);

  final Country country;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final sel = newValue.selection.end.clamp(0, newValue.text.length);
    var digitsBeforeCaret = _digitCount(newValue.text.substring(0, sel));

    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    // A pasted/autofilled full number (e.g. "+12025550186") carries the country
    // code; drop it so it doesn't get mistaken for national digits.
    if (digits.length > country.maxLen && digits.startsWith(country.dialCode)) {
      final cc = country.dialCode.length;
      digits = digits.substring(cc);
      digitsBeforeCaret = (digitsBeforeCaret - cc).clamp(0, digits.length);
    }
    if (digits.length > country.maxLen) {
      digits = digits.substring(0, country.maxLen);
      if (digitsBeforeCaret > country.maxLen) digitsBeforeCaret = country.maxLen;
    }

    final text = _format(digits);

    // Re-place the caret after the same count of digits it followed before.
    var offset = 0, seen = 0;
    while (offset < text.length && seen < digitsBeforeCaret) {
      if (_isAsciiDigit(text.codeUnitAt(offset))) seen++;
      offset++;
    }
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset));
  }

  // Only +1 (US/Canada) gets grouping; other countries stay plain digits so we
  // don't impose a wrong national format.
  String _format(String digits) {
    if (country.dialCode != '1') return digits;
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i == 0) b.write('(');
      if (i == 3) b.write(') ');
      if (i == 6) b.write('-');
      b.write(digits[i]);
    }
    return b.toString();
  }

  int _digitCount(String s) => s.replaceAll(RegExp(r'\D'), '').length;

  bool _isAsciiDigit(int c) => c >= 0x30 && c <= 0x39;
}

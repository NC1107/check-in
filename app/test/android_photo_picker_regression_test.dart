import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Gallery photo GPS on Android only survives because image_picker_android takes the legacy
/// ACTION_GET_CONTENT picker while `ImagePickerAndroid.useAndroidPhotoPicker` is left at its
/// default false - that picker hands back a URI whose redaction the app's own
/// ACCESS_MEDIA_LOCATION grant controls (see AndroidManifest.xml and
/// MainActivity.ensureMediaLocationPermission). The modern Android 13+ photo picker
/// (PickVisualMedia) enforces its own redaction that grant does not reach, and the plugin's
/// own doc on the flag says its default "is subject to change" on a future upgrade.
///
/// If anyone ever sets that flag true - for the nicer system picker UI, or a plugin bump
/// flips the default - gallery photo locations silently go back to missing, with no error
/// anywhere to point at why. This is a cheap trip-wire for that: it fails the moment the app
/// opts in, so whoever does it has to come explain why here instead of finding out from a
/// support message.
void main() {
  test('the app never opts into the Android photo picker (it silently drops GPS)', () {
    final offenders = <String>[];
    for (final entry in Directory('lib').listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) continue;
      final content = entry.readAsStringSync();
      if (RegExp(r'useAndroidPhotoPicker\s*=\s*true').hasMatch(content)) {
        offenders.add(entry.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'Setting useAndroidPhotoPicker = true silently breaks gallery photo '
            'locations on Android - see this test\'s doc comment before flipping it.');
  });
}

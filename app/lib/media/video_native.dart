import 'package:flutter/services.dart';

/// The two native operations a clip needs before it can be posted, behind one method
/// channel so the Dart compose flow can be tested against a fake without a device.
///
/// Both are things no maintained Flutter package covers well: a lossless range cut that
/// keeps the rotation matrix (so a portrait clip does not post sideways), and reading the
/// MP4 location atom that `native_exif` (photo-only) cannot. Everything around them - the
/// trim window math, the encode, the upload - stays pure Dart on the other side of this
/// seam.
class VideoNative {
  const VideoNative();

  static const MethodChannel _channel = MethodChannel('checkin/video');

  /// Losslessly copies the sample range `[startMs, endMs)` of the clip at [path] into a new
  /// file and returns its path. No re-encode: the platform remuxes the range and preserves
  /// the source rotation, so the caller can hand the result straight to the size encoder.
  Future<String> trim(String path, int startMs, int endMs) async {
    final out = await _channel.invokeMethod<String>('trim', {
      'path': path,
      'startMs': startMs,
      'endMs': endMs,
    });
    if (out == null || out.isEmpty) {
      throw const VideoNativeException('trim returned no output path');
    }
    return out;
  }

  /// Reads the recording location stored in the MP4 (the ISO6709 atom), or null when the
  /// clip carries none. The coordinate is reverse-geocoded to a coarse place and never
  /// leaves the device raw, exactly as a photo's GPS is.
  Future<({double lat, double lng})?> location(String path) async {
    final r = await _channel.invokeMapMethod<String, dynamic>('location', {'path': path});
    if (r == null) return null;
    final lat = (r['lat'] as num?)?.toDouble();
    final lng = (r['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return (lat: lat, lng: lng);
  }

  /// Switches the app's audio session to a category that honors the Ring/Silent switch, so a
  /// clip's audio follows the ringer rather than playing through silent mode. video_player
  /// forces the playback category (sound even when silenced) on its first init and never
  /// downgrades, so this is re-asserted once a clip is ready to play. Best-effort: hosts
  /// without the native handler (Android, tests) no-op. Device-verified on iOS.
  Future<void> respectSilentSwitch() async {
    try {
      await _channel.invokeMethod<void>('respectSilentSwitch');
    } catch (_) {
      // No native handler: the platform's own default already respects the silent switch.
    }
  }
}

/// A native video op failed in a way the compose flow can catch without crashing the post.
class VideoNativeException implements Exception {
  const VideoNativeException(this.message);

  final String message;

  @override
  String toString() => 'VideoNativeException: $message';
}

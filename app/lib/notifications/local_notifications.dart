import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The one on-device notification plugin. It is a process-wide singleton, so every feature
/// that shows or schedules local notifications (foreground push banners, birthday
/// reminders) must share this initialization: a second `initialize` call replaces the
/// plugin's tap callback, silently unrouting taps registered by the first.
final FlutterLocalNotificationsPlugin localNotifications = FlutterLocalNotificationsPlugin();

/// Where notification taps land once the app is ready. HomeShell installs the real
/// handler; a tap that arrives first (cold start from a notification) is buffered.
typedef PushTapHandler = void Function(Map<String, dynamic> data);
PushTapHandler? _tapHandler;
Map<String, dynamic>? _pendingTap;

void setPushTapHandler(PushTapHandler handler) {
  _tapHandler = handler;
  final pending = _pendingTap;
  if (pending != null) {
    _pendingTap = null;
    handler(pending);
  }
}

void dispatchNotificationTap(Map<String, dynamic> data) {
  final handler = _tapHandler;
  if (handler != null) {
    handler(data);
  } else {
    _pendingTap = data;
  }
}

/// Decodes a tapped local notification's payload and routes it. Payloads that aren't a
/// JSON object (e.g. a birthday reminder, which carries none) are ignored.
void handleNotificationResponse(NotificationResponse response) {
  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;
  try {
    dispatchNotificationTap((jsonDecode(payload) as Map).cast<String, dynamic>());
  } catch (_) {}
}

Future<void>? _initialization;

/// Initializes the shared plugin once, always registering the tap callback. iOS permission
/// is never requested here: the system prompt is owned by requestDeviceToken() so it only
/// appears when the user has seen the feature.
Future<void> ensureLocalNotificationsInitialized() => _initialization ??= _initialize();

Future<void> _initialize() async {
  const settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    ),
  );
  try {
    await localNotifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: handleNotificationResponse,
    );
  } catch (_) {
    _initialization = null;
    rethrow;
  }
}

/// A deterministic 31-bit id for [key]. FNV-1a keeps it stable across launches (Dart's
/// String.hashCode isn't guaranteed to be), so re-posting replaces rather than stacks.
int stableNotificationId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

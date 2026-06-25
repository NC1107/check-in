import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/api_client.dart';

/// Cloud push (FCM). A single Firebase channel reaches Android directly and iOS through
/// APNs. Server payloads carry only a short title/body — never post content — so the
/// providers see as little as possible. Birthday reminders stay on-device (see
/// birthday_notifier.dart); this file is just for server-originated posts/replies.

/// Background/terminated-state handler. Android and iOS render `notification` payloads
/// in the system tray automatically, so this only needs to exist (and init Firebase in
/// its isolate) to satisfy the plugin and leave room for future data handling.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();

/// High-importance channel so foreground messages show as a heads-up banner on Android.
const AndroidNotificationChannel _channel = AndroidNotificationChannel(
  'checkin_messages',
  'Check-In notifications',
  description: 'New check-ins and replies from your group',
  importance: Importance.high,
);

bool _supported = !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// initPush wires up Firebase + local-notification plumbing. Call once at startup (after
/// Firebase.initializeApp). Best-effort: any failure leaves the app running without push.
Future<void> initPush() async {
  if (!_supported) return;
  try {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    await _local.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        // We request permission explicitly via requestDeviceToken(); don't prompt here.
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ));
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    // iOS: let the system present banners while the app is foregrounded.
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);

    // Android won't show a foregrounded message on its own — render it ourselves.
    FirebaseMessaging.onMessage.listen(_showForeground);
  } catch (_) {
    // Push is optional; never block startup on it.
  }
}

void _showForeground(RemoteMessage message) {
  // iOS handles foreground presentation via setForegroundNotificationPresentationOptions,
  // so showing here too would double up. Only render manually on Android.
  if (defaultTargetPlatform != TargetPlatform.android) return;
  final n = message.notification;
  if (n == null) return;
  _local.show(
    n.hashCode,
    n.title,
    n.body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
    ),
  );
}

/// requestDeviceToken asks for notification permission, then registers this device's FCM
/// token with the server so it can receive push. Also keeps the token fresh on rotation.
/// Idempotent — safe to call on every launch and right after login.
Future<void> requestDeviceToken(ApiClient api) async {
  if (!_supported) return;
  try {
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return;

    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    // iOS hands FCM the APNs token asynchronously; getToken() stays null (or throws)
    // until it's set. Wait briefly for it so the first launch registers reliably.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      for (var i = 0; i < 10 && (await messaging.getAPNSToken()) == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    final token = await messaging.getToken();
    if (token != null) {
      await api.registerDevice(token: token, platform: platform);
    }
    // Re-register whenever FCM rotates the token.
    messaging.onTokenRefresh.listen((t) {
      api.registerDevice(token: t, platform: platform).catchError((_) {});
    });
  } catch (_) {
    // Network hiccup or unsupported device — try again next launch.
  }
}

/// clearDeviceToken drops this device's token server-side (call on logout, while the
/// session is still valid) so a signed-out phone stops getting this account's push.
Future<void> clearDeviceToken(ApiClient api) async {
  if (!_supported) return;
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await api.unregisterDevice(token);
  } catch (_) {
    // Best-effort.
  }
}

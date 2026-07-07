import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/api_client.dart';

/// Cloud push (FCM). A single Firebase channel reaches Android directly and iOS through
/// APNs. Server payloads carry only a short title/body - never post content - so the
/// providers see as little as possible. Birthday reminders stay on-device (see
/// birthday_notifier.dart); this file is just for server-originated posts/replies.
///
/// Multi-group: the one device token is registered with EVERY connected server, and each
/// push's data payload carries its origin server ("server": public base URL) so a tap
/// can be routed to the right group.

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

void _dispatchTap(Map<String, dynamic> data) {
  final handler = _tapHandler;
  if (handler != null) {
    handler(data);
  } else {
    _pendingTap = data;
  }
}

/// initPush wires up Firebase + local-notification plumbing. Call once at startup (after
/// Firebase.initializeApp). Best-effort: any failure leaves the app running without push.
Future<void> initPush() async {
  if (!_supported) return;
  try {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    await _local.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // We request permission explicitly via requestDeviceToken(); don't prompt here.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      // Taps on our own foreground-rendered Android banners carry the FCM data payload.
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          _dispatchTap((jsonDecode(payload) as Map).cast<String, dynamic>());
        } catch (_) {}
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    // iOS: let the system present banners while the app is foregrounded.
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);

    // Android won't show a foregrounded message on its own - render it ourselves.
    FirebaseMessaging.onMessage.listen(_showForeground);

    // System-tray taps: background → onMessageOpenedApp; terminated → getInitialMessage.
    FirebaseMessaging.onMessageOpenedApp
        .listen((m) => _dispatchTap(Map<String, dynamic>.from(m.data)));
    // getInitialMessage can hang on iOS, and initPush runs before runApp - awaiting it
    // here left the app stuck on the launch screen. Resolve it in the background instead;
    // a tap that arrives before HomeShell installs the handler is buffered (_pendingTap).
    unawaited(FirebaseMessaging.instance.getInitialMessage().then((initial) {
      if (initial != null) _dispatchTap(Map<String, dynamic>.from(initial.data));
    }).catchError((_) {}));
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
    payload: jsonEncode(message.data),
  );
}

StreamSubscription<String>? _refreshSub;

/// requestDeviceToken asks for notification permission, then registers this device's FCM
/// token with every connected server so each group can push. Also keeps the token fresh
/// on rotation. Idempotent (the servers upsert on the token) - safe to call on every
/// launch, after login, and whenever the set of groups changes.
Future<void> requestDeviceToken(List<ApiClient> apis) async {
  if (!_supported || apis.isEmpty) return;
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
      for (final api in apis) {
        // Per-server registration is independent; one unreachable group must not stop
        // the others from getting push.
        try {
          await api.registerDevice(token: token, platform: platform);
        } catch (_) {}
      }
    }
    // Re-register everywhere whenever FCM rotates the token. Replace (don't stack) the
    // listener so re-registration after a group change doesn't duplicate work.
    await _refreshSub?.cancel();
    _refreshSub = messaging.onTokenRefresh.listen((t) {
      for (final api in apis) {
        api.registerDevice(token: t, platform: platform).catchError((_) {});
      }
    });
  } catch (_) {
    // Network hiccup or unsupported device - try again next launch.
  }
}

/// clearDeviceToken drops this device's token on ONE server (call when logging out of or
/// leaving that group, while its session is still valid) so that group stops pushing to
/// this phone. Other groups keep their registration.
Future<void> clearDeviceToken(ApiClient api) async {
  if (!_supported) return;
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await api.unregisterDevice(token);
  } catch (_) {
    // Best-effort.
  }
}

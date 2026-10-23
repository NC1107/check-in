import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin/notifications/local_notifications.dart';

NotificationResponse _tap(String? payload) => NotificationResponse(
    notificationResponseType: NotificationResponseType.selectedNotification, payload: payload);

void main() {
  test('a tapped push banner routes its FCM payload to the handler', () {
    Map<String, dynamic>? got;
    setPushTapHandler((d) => got = d);
    handleNotificationResponse(_tap('{"server":"https://a.example","post_id":7}'));
    expect(got, {'server': 'https://a.example', 'post_id': 7});
  });

  test('payload-less taps (birthday reminders) and malformed payloads are ignored', () {
    var calls = 0;
    setPushTapHandler((_) => calls++);
    handleNotificationResponse(_tap(null));
    handleNotificationResponse(_tap(''));
    handleNotificationResponse(_tap('not json'));
    expect(calls, 0);
  });

  test('stable ids are deterministic, 31-bit and distinct per key', () {
    expect(stableNotificationId('msg-1'), stableNotificationId('msg-1'));
    expect(stableNotificationId('msg-1'), isNot(stableNotificationId('msg-2')));
    expect(stableNotificationId('msg-1'), inInclusiveRange(0, 0x7fffffff));
  });
}

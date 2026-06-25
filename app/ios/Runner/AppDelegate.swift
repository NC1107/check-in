import FirebaseCore
import FirebaseMessaging
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
    NSLog("[CHECKIN-NATIVE] didFinishLaunching configured=\(FirebaseApp.app() != nil)")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Configure Firebase before the plugins register so firebase_messaging's auto-init
    // finds a configured default app.
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
    NSLog("[CHECKIN-NATIVE] preRegister configured=\(FirebaseApp.app() != nil)")
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    NSLog("[CHECKIN-NATIVE] postRegister configured=\(FirebaseApp.app() != nil)")
  }

  // Forward the APNs token to FCM explicitly. The implicit-engine + SceneDelegate lifecycle
  // can prevent firebase_messaging's swizzling from capturing it, which leaves getToken()
  // stuck and no token ever registers. Setting it here guarantees the hand-off.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    NSLog("[CHECKIN-NATIVE] APNs token received: \(deviceToken.count) bytes")
    Messaging.messaging().apnsToken = deviceToken
    super.application(
      application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("[CHECKIN-NATIVE] APNs registration FAILED: \(error.localizedDescription)")
    super.application(
      application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}

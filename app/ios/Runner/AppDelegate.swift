import FirebaseCore
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure Firebase natively at launch. With this app's SceneDelegate lifecycle the
    // Dart-side Firebase.initializeApp() doesn't reliably configure the default app before
    // firebase_messaging's auto-init needs it (logs "No app has been configured yet"), so
    // do it here first. The Dart call then just adopts this already-configured app.
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Configure Firebase *before* registering plugins: firebase_messaging's auto-init runs
    // during registration and needs the default app to already exist. In this implicit-
    // engine template that happens before didFinishLaunchingWithOptions, so configuring
    // there alone was too late ("default Firebase app has not yet been configured").
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Upozornění s výsledkem Shazamu z Ovládacího centra (BackgroundShazam).
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Live Activity "Právě hraje" (viz NowPlayingActivity.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NowPlayingActivity") {
      NowPlayingActivityBridge.register(with: registrar.messenger())
    }
    // Ovládací centrum / upozornění -> obrazovka ve Flutteru (BackgroundShazam.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeNav") {
      NativeNavBridge.register(with: registrar.messenger())
    }
  }

  // Upozornění ukázat i s otevřenou appkou.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  // Klepnutí na výsledek Shazamu otevře sbírku Shazam.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let route = response.notification.request.content.userInfo["route"] as? String {
      OpentifyShared.requestRoute(route)
    }
    completionHandler()
  }
}

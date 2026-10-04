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
    // Systémové sklo (Liquid Glass) pod plovoucími lištami (viz NativeGlassView níž).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeGlass") {
      registrar.register(NativeGlassFactory(), withId: "opentify/glass")
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

// MARK: - Systémové sklo

/// Skutečné Liquid Glass z iOS 26 (`UIGlassEffect`) jako platform view pod
/// plovoucími prvky Flutteru (tab bar, kapsle, mini přehrávač). Flutter
/// kreslí obsah pod platform view do spodní vrstvy, takže ho systémové sklo
/// opravdu láme a rozmazává -- včetně barevného (duhového) okraje. Obsah
/// skla (ikony, text) kreslí Flutter nad ním. Starší iOS / build bez
/// Xcode 26: obyčejný systémový materiál.
final class NativeGlassFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    NativeGlassView(frame: frame, args: args as? [String: Any] ?? [:])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class NativeGlassView: NSObject, FlutterPlatformView {
  private let host: GlassHostView

  init(frame: CGRect, args: [String: Any]) {
    host = GlassHostView(
      frame: frame,
      radius: CGFloat((args["radius"] as? NSNumber)?.doubleValue ?? 0),
      dark: (args["dark"] as? Bool) ?? true
    )
    super.init()
  }

  func view() -> UIView { host }
}

final class GlassHostView: UIView {
  private let effectView: UIVisualEffectView
  private let radius: CGFloat

  init(frame: CGRect, radius: CGFloat, dark: Bool) {
    self.radius = radius
    effectView = UIVisualEffectView(effect: GlassHostView.makeEffect())
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    overrideUserInterfaceStyle = dark ? .dark : .light
    effectView.frame = bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    addSubview(effectView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Kapsle se při morfu zužuje -- poloměr nikdy víc než půl výšky.
    effectView.layer.cornerRadius = min(radius, bounds.height / 2, bounds.width / 2)
  }

  private static func makeEffect() -> UIVisualEffect {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return UIGlassEffect()
    }
    #endif
    return UIBlurEffect(style: .systemUltraThinMaterial)
  }
}

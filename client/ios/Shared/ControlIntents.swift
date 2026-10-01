import AppIntents
import Foundation

/// Akce tlačítek v Ovládacím centru. Jsou v appce I v rozšíření (ovládací
/// prvek na ně odkazuje); `perform` spouští iOS v procesu APPKY.
///
/// Dřív obě vracely `OpenURLIntent("opentify://...")` a nedělo se nic (ani
/// s otevřenou appkou) -- vlastní adresu tudy iOS neotevře. Teď:
///  - Ladička: `openAppWhenRun` otevře appku a cesta `/tuner` se předá
///    Flutteru přes kanál `opentify/nav` (OpentifyShared.pendingRoute).
///  - Shazam: stejně, `/shazam?start=1` (rozpoznávání se spustí samo).
@available(iOS 18.0, *)
struct OpenOpentifyTunerIntent: AppIntent {
  static var title: LocalizedStringResource = "Ladička"
  static var description = IntentDescription("Otevře ladičku v Opentify.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    OpentifyShared.requestRoute("/tuner")
    OpentifyShared.report("control-tuner", "perform v \(OpentifyShared.processName)")
    return .result()
  }
}

/// Shazam: otevře appku a rozpoznávání rovnou spustí (`/shazam?start=1`).
/// Varianta na pozadí (`AudioRecordingIntent`, Runner/BackgroundShazam.swift)
/// nefungovala: iOS ji spouštěl v ROZŠÍŘENÍ, kde mikrofon nejde (živě, log
/// "perform v rozšíření") -- stejný postup jako Ladička je spolehlivý.
@available(iOS 18.0, *)
struct OpenOpentifyShazamIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Shazam"
  static var description = IntentDescription("Otevře Opentify a začne poznávat skladbu.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    OpentifyShared.requestRoute("/shazam?start=1")
    OpentifyShared.report("control-shazam", "perform v \(OpentifyShared.processName)")
    return .result()
  }
}

/// Sdílená data appky a rozšíření (App Group): adresa serveru a klíč
/// zařízení (posílá je Flutter, NativeNav.syncConfig) a čekající cesta.
enum OpentifyShared {
  static var defaults: UserDefaults { UserDefaults(suiteName: OpentifyAppGroup.id) ?? .standard }

  static var apiBase: String? { defaults.string(forKey: "apiBase") }
  static var token: String? { defaults.string(forKey: "token") }
  static var actAs: String? { defaults.string(forKey: "actAs") }

  static var processName: String { Bundle.main.bundleURL.pathExtension == "appex" ? "rozšíření" : "appce" }

  static let routeNotification = Notification.Name("OpentifyPendingRoute")

  /// Cestu si vyzvedne Flutter (hned, nebo po otevření appky).
  static func requestRoute(_ route: String) {
    defaults.set(route, forKey: "pendingRoute")
    NotificationCenter.default.post(name: routeNotification, object: nil)
  }

  static func takeRoute() -> String? {
    let route = defaults.string(forKey: "pendingRoute")
    defaults.removeObject(forKey: "pendingRoute")
    return route
  }

  static func authorize(_ request: inout URLRequest) {
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let actAs { request.setValue(actAs, forHTTPHeaderField: "X-Act-As") }
  }

  /// Záznam do logu API (`POST /client-log`), stejně jako z Flutteru --
  /// bez toho není z nativní části vidět nic. Navíc do lokálního deníku
  /// (`takeLog`): appku na pozadí může iOS uspat dřív, než požadavek odejde
  /// (živě: Shazam z Ovládacího centra nenahlásil nic) -- deník pak odešle
  /// Flutter při dalším otevření.
  static func report(_ kind: String, _ detail: String) {
    log("\(kind): \(detail)")
    guard let base = apiBase, let url = URL(string: "\(base)/client-log") else { return }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authorize(&request)
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "kind": kind, "detail": detail, "platform": "ios-native",
    ])
    URLSession.shared.dataTask(with: request).resume()
  }

  static func log(_ line: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    var lines = defaults.stringArray(forKey: "nativeLog") ?? []
    lines.append("\(stamp) [\(processName)] \(line)")
    defaults.set(Array(lines.suffix(80)), forKey: "nativeLog")
  }

  static func takeLog() -> [String] {
    let lines = defaults.stringArray(forKey: "nativeLog") ?? []
    defaults.removeObject(forKey: "nativeLog")
    return lines
  }
}

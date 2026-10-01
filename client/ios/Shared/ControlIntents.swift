import AppIntents
import Foundation

/// Akce tlačítek v Ovládacím centru. Musí být v appce I v rozšíření
/// (`openAppWhenRun` -- iOS spustí `perform` v procesu appky, ta se otevře
/// a přejde na obrazovku přes vlastní adresu `opentify://app/...`).
/// Samotný `OpenURLIntent` přímo v ovládacím prvku nedělal nic (živě).
@available(iOS 18.0, *)
struct OpenOpentifyShazamIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Shazam"
  static var description = IntentDescription("Otevře Opentify a začne poznávat skladbu.")
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult & OpensIntent {
    .result(opensIntent: OpenURLIntent(URL(string: "opentify://app/shazam?start=1")!))
  }
}

@available(iOS 18.0, *)
struct OpenOpentifyTunerIntent: AppIntent {
  static var title: LocalizedStringResource = "Ladička"
  static var description = IntentDescription("Otevře ladičku v Opentify.")
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult & OpensIntent {
    .result(opensIntent: OpenURLIntent(URL(string: "opentify://app/tuner")!))
  }
}

import ActivityKit
import Foundation

/// Stav Live Activity "Právě hraje" -- sdílený appkou (Runner) i rozšířením
/// (OpentifyWidgets). Mění se při každé skladbě / play-pauze; SwiftUI
/// v rozšíření pak tvar obalu a barvu plynule přelije (animatableData).
@available(iOS 16.1, *)
struct NowPlayingAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var artist: String
    /// Soubor s obalem ve sdíleném kontejneru (App Group), nebo nil.
    var artFile: String?
    /// Index tvaru výřezu (viz `ShapePreset`).
    var shape: Int
    /// Barva skladby, "#RRGGBB".
    var color: String
    var playing: Bool
  }
}

/// App Group sdílená appkou a rozšířením. SideStore/AltStore ji při podpisu
/// přejmenuje (přidá ID týmu) a skutečné jméno zapíše do Info.plist jako
/// `ALTAppGroups` -- proto se čte odtud, s výchozí hodnotou pro jistotu.
enum OpentifyAppGroup {
  static let fallback = "group.app.opentify"

  static var id: String {
    if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], let first = groups.first {
      return first
    }
    // Rozšíření leží v Opentify.app/PlugIns/X.appex -- zkusit Info.plist appky.
    let hostPlist = Bundle.main.bundleURL
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Info.plist")
    if let dict = NSDictionary(contentsOf: hostPlist),
       let groups = dict["ALTAppGroups"] as? [String], let first = groups.first {
      return first
    }
    return fallback
  }

  static var container: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
  }
}

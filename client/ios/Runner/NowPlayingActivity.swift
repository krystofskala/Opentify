import ActivityKit
import Flutter
import Foundation

/// Kanál `opentify/live_activity`: Flutter (AudioPlayerController) posílá
/// stav právě hrající skladby, tady se z něj spustí / aktualizuje Live
/// Activity (zamčená obrazovka + Dynamic Island, vzhled v OpentifyWidgets).
enum NowPlayingActivityBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "opentify/live_activity", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard #available(iOS 16.2, *) else {
        result(nil)
        return
      }
      switch call.method {
      case "update":
        let args = call.arguments as? [String: Any] ?? [:]
        Task {
          await NowPlayingActivityController.shared.update(args)
          result(nil)
        }
      case "end":
        Task {
          await NowPlayingActivityController.shared.end()
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

@available(iOS 16.2, *)
actor NowPlayingActivityController {
  static let shared = NowPlayingActivityController()

  private var activity: Activity<NowPlayingAttributes>?
  private var lastArtFile: String?

  func update(_ args: [String: Any]) async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    var artFile = lastArtFile
    if let art = args["art"] as? FlutterStandardTypedData, let key = args["artKey"] as? String,
       let container = OpentifyAppGroup.container {
      let safe = String(key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(48))
      let name = "art-\(safe).png"
      if name != lastArtFile {
        let url = container.appendingPathComponent(name)
        try? art.data.write(to: url, options: .atomic)
        if let old = lastArtFile {
          try? FileManager.default.removeItem(at: container.appendingPathComponent(old))
        }
        lastArtFile = name
      }
      artFile = name
    } else if args["artKey"] == nil {
      artFile = nil
    }
    let state = NowPlayingAttributes.ContentState(
      title: args["title"] as? String ?? "",
      artist: args["artist"] as? String ?? "",
      artFile: artFile,
      shape: args["shape"] as? Int ?? 0,
      color: args["color"] as? String ?? "#5B3FD6",
      playing: args["playing"] as? Bool ?? false
    )
    let content = ActivityContent(state: state, staleDate: nil)
    if let current = activity ?? Activity<NowPlayingAttributes>.activities.first {
      activity = current
      await current.update(content)
    } else {
      activity = try? Activity.request(attributes: NowPlayingAttributes(), content: content, pushType: nil)
    }
  }

  func end() async {
    for item in Activity<NowPlayingAttributes>.activities {
      await item.end(nil, dismissalPolicy: .immediate)
    }
    activity = nil
  }
}

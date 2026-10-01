import ActivityKit
import AVFoundation
import Flutter
import Foundation
import UserNotifications

/// Kanál `opentify/nav` (Flutter: lib/core/native_nav.dart): konfigurace pro
/// nativní Shazam a předání cest z Ovládacího centra / upozornění.
enum NativeNavBridge {
  private static var channel: FlutterMethodChannel?
  private static var observer: NSObjectProtocol?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "opentify/nav", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "config":
        let args = call.arguments as? [String: Any] ?? [:]
        let defaults = OpentifyShared.defaults
        for key in ["apiBase", "token", "actAs"] {
          if let value = args[key] as? String { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        result(nil)
      case "pending":
        result(OpentifyShared.takeRoute())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // Appka už běží (Ovládací centrum nad otevřenou appkou): předat hned.
    observer = NotificationCenter.default.addObserver(
      forName: OpentifyShared.routeNotification, object: nil, queue: .main
    ) { _ in
      if let route = OpentifyShared.takeRoute() { self.channel?.invokeMethod("open", arguments: route) }
    }
  }
}

/// Open Shazam z Ovládacího centra: appka se neotevře, nahraje pár sekund
/// z mikrofonu, pošle je vlastnímu serveru (`POST /recognize`, ten skladbu
/// uloží do sbírky Shazam) a výsledek oznámí upozorněním. Během nahrávání
/// musí běžet Live Activity (podmínka iOS pro nahrávání na pozadí).
/// Zvuk se nikam neukládá -- dočasný soubor se hned maže.
@available(iOS 18.0, *)
actor BackgroundShazam {
  static let shared = BackgroundShazam()

  private var running = false
  private var activity: Activity<NowPlayingAttributes>?

  func run() async {
    guard !running else { return }
    running = true
    defer { running = false }

    guard AVAudioApplication.shared.recordPermission == .granted else {
      await notify(title: "Shazam potřebuje mikrofon", body: "Otevři jednou Shazam v appce a povol mikrofon.")
      OpentifyShared.report("control-shazam", "mikrofon nepovolen: \(AVAudioApplication.shared.recordPermission.rawValue)")
      return
    }
    await startActivity(title: "Poslouchám…", artist: "Open Shazam")
    let session = AVAudioSession.sharedInstance()
    let previousCategory = session.category
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
      try session.setActive(true)
    } catch {
      OpentifyShared.report("control-shazam", "audio session: \(error)")
    }

    var outcome: Outcome = .failed("nic nenahráno")
    // Jako v appce: zkusit krátký úsek, když nic, ještě jeden.
    for seconds in [7.0, 8.0] {
      guard let clip = await record(seconds: seconds) else { break }
      outcome = await recognize(clip)
      if case .notFound = outcome { continue }
      break
    }
    try? session.setCategory(previousCategory == .playAndRecord ? .playback : previousCategory)

    switch outcome {
    case let .found(title, artist):
      await endActivity(title: title, artist: artist)
      await notify(title: title, body: "\(artist) · uloženo do Shazamu v Opentify")
    case .notFound:
      await endActivity(title: "Nic jsem nepoznal", artist: "Open Shazam")
      await notify(title: "Shazam nic nepoznal", body: "Zkus to blíž u reproduktoru.")
    case let .failed(reason):
      await endActivity(title: "Shazam selhal", artist: reason)
      await notify(title: "Shazam selhal", body: reason)
      OpentifyShared.report("control-shazam", "selhalo: \(reason)")
    }
  }

  private enum Outcome {
    case found(String, String)
    case notFound
    case failed(String)
  }

  private func record(seconds: Double) async -> Data? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shazam-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    do {
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      guard recorder.record(forDuration: seconds) else {
        OpentifyShared.report("control-shazam", "record() vrátil false")
        return nil
      }
      try await Task.sleep(nanoseconds: UInt64((seconds + 0.4) * 1_000_000_000))
      recorder.stop()
      return try Data(contentsOf: url)
    } catch {
      OpentifyShared.report("control-shazam", "nahrávání: \(error)")
      return nil
    }
  }

  private func recognize(_ clip: Data) async -> Outcome {
    guard let base = OpentifyShared.apiBase, let url = URL(string: "\(base)/recognize") else {
      return .failed("Otevři jednou appku (chybí adresa serveru).")
    }
    let boundary = "opentify-\(UUID().uuidString)"
    var request = URLRequest(url: url, timeoutInterval: 40)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    OpentifyShared.authorize(&request)
    var body = Data()
    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(clip)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    do {
      let (data, response) = try await URLSession.shared.upload(for: request, from: body)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      guard status == 200 else {
        return .failed(json["detail"] as? String ?? "server odpověděl \(status)")
      }
      guard json["found"] as? Bool == true else { return .notFound }
      return .found(json["title"] as? String ?? "?", json["artist"] as? String ?? "")
    } catch {
      return .failed("server nedostupný (Tailscale?)")
    }
  }

  private func startActivity(title: String, artist: String) async {
    let state = NowPlayingAttributes.ContentState(
      title: title, artist: artist, artFile: nil, shape: 0, color: "#5B3FD6", playing: true)
    do {
      activity = try Activity.request(
        attributes: NowPlayingAttributes(), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    } catch {
      OpentifyShared.report("control-shazam", "Live Activity: \(error)")
    }
  }

  private func endActivity(title: String, artist: String) async {
    let state = NowPlayingAttributes.ContentState(
      title: title, artist: artist, artFile: nil, shape: 0, color: "#5B3FD6", playing: false)
    await activity?.end(
      ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(6)))
    activity = nil
  }

  private func notify(title: String, body: String) async {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = ["route": "/library/shazam"]
    let request = UNNotificationRequest(identifier: "shazam-\(UUID().uuidString)", content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }
}

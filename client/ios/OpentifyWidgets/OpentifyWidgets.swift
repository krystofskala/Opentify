import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OpentifyWidgets: WidgetBundle {
  var body: some Widget {
    NowPlayingLiveActivity()
    if #available(iOS 18.0, *) {
      ShazamControl()
      TunerControl()
    }
  }
}

// MARK: - Fun shape (M3 Expressive "cookie" s plynulým přechodem)

/// Předvolby tvaru: počet laloků a hloubka. Každá skladba dostane jednu
/// (podle id), při změně se tvar přelije -- animatableData interpoluje
/// laloky i hloubku.
struct ShapePreset {
  let lobes: Double
  let depth: Double
  let spin: Double

  static let all: [ShapePreset] = [
    ShapePreset(lobes: 9, depth: 0.09, spin: 0),   // cookie
    ShapePreset(lobes: 6, depth: 0.14, spin: 15),  // květina
    ShapePreset(lobes: 4, depth: 0.12, spin: 45),  // čtyřlístek
    ShapePreset(lobes: 12, depth: 0.06, spin: 0),  // sluníčko
    ShapePreset(lobes: 5, depth: 0.10, spin: 36),  // hvězdička
    ShapePreset(lobes: 8, depth: 0.03, spin: 0),   // skoro kruh
  ]

  static func at(_ index: Int) -> ShapePreset { all[((index % all.count) + all.count) % all.count] }
}

struct MorphShape: Shape {
  var lobes: Double
  var depth: Double
  var spin: Double

  init(_ preset: ShapePreset) {
    lobes = preset.lobes
    depth = preset.depth
    spin = preset.spin
  }

  var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
    get { AnimatablePair(AnimatablePair(lobes, depth), spin) }
    set {
      lobes = newValue.first.first
      depth = newValue.first.second
      spin = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    let steps = 180
    let rotation = spin * .pi / 180
    var path = Path()
    for i in 0...steps {
      let t = Double(i) / Double(steps) * 2 * .pi
      // Laloky jako kosinus: plné u 1, zúžené o `depth`.
      let r = radius * (1 - depth * (0.5 - 0.5 * cos(lobes * t)))
      let point = CGPoint(x: center.x + r * cos(t + rotation), y: center.y + r * sin(t + rotation))
      if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
  }
}

// MARK: - Live Activity "Právě hraje"

extension Color {
  init(hex: String) {
    var value: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
    self.init(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }
}

struct ArtworkView: View {
  let state: NowPlayingAttributes.ContentState
  let size: CGFloat

  var body: some View {
    let preset = ShapePreset.at(state.shape)
    Group {
      if let file = state.artFile,
         let url = OpentifyAppGroup.container?.appendingPathComponent(file),
         let image = UIImage(contentsOfFile: url.path),
         // Zmenšit na skutečnou velikost (3×) -- v Dynamic Islandu se
         // větší obrázek nevykreslil a celá kapka zůstala šedá (živě).
         let thumb = image.preparingThumbnail(of: CGSize(width: size * 3, height: size * 3)) {
        Image(uiImage: thumb).resizable().aspectRatio(contentMode: .fill)
      } else {
        ZStack {
          Color(hex: state.color)
          Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(MorphShape(preset))
    .animation(.spring(response: 0.9, dampingFraction: 0.7), value: state.shape)
    .contentTransition(.opacity)
  }
}

struct NowPlayingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: NowPlayingAttributes.self) { context in
      let state = context.state
      HStack(spacing: 14) {
        ArtworkView(state: state, size: 64)
        VStack(alignment: .leading, spacing: 2) {
          Text(state.title)
            .font(.headline).fontWeight(.bold).lineLimit(1)
            .contentTransition(.opacity)
          Text(state.artist)
            .font(.subheadline).lineLimit(1).opacity(0.8)
            .contentTransition(.opacity)
        }
        Spacer(minLength: 0)
        Image(systemName: state.playing ? "waveform" : "pause.fill")
          .font(.title3)
          .symbolEffect(.variableColor.iterative, isActive: state.playing)
          .contentTransition(.symbolEffect(.replace))
      }
      .foregroundStyle(.white)
      .padding(16)
      .activityBackgroundTint(Color(hex: state.color).opacity(0.85))
      .activitySystemActionForegroundColor(.white)
      .widgetURL(URL(string: "opentify://app/"))
    } dynamicIsland: { context in
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          ArtworkView(state: state, size: 52)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(state.title).font(.headline).lineLimit(1)
            Text(state.artist).font(.subheadline).lineLimit(1).opacity(0.75)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Image(systemName: state.playing ? "waveform" : "pause.fill")
            .foregroundStyle(Color(hex: state.color))
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: state.playing)
        }
      } compactLeading: {
        ArtworkView(state: state, size: 22)
      } compactTrailing: {
        // Jako systémový přehrávač: vlnovka "hraje" v barvě skladby.
        Image(systemName: state.playing ? "waveform" : "pause.fill")
          .foregroundStyle(Color(hex: state.color))
          .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: state.playing)
          .contentTransition(.symbolEffect(.replace))
      } minimal: {
        ArtworkView(state: state, size: 22)
      }
      .widgetURL(URL(string: "opentify://app/"))
      .keylineTint(Color(hex: state.color))
    }
  }
}

// MARK: - Ovládací centrum (iOS 18): Open Shazam a ladička

@available(iOS 18.0, *)
struct ShazamControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "app.opentify.control.shazam") {
      ControlWidgetButton(action: OpenOpentifyShazamIntent()) {
        Label("Open Shazam", systemImage: "shazam.logo")
      }
    }
    .displayName("Open Shazam")
    .description("Pozná skladbu, která hraje kolem, a uloží ji na později.")
  }
}

@available(iOS 18.0, *)
struct TunerControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "app.opentify.control.tuner") {
      ControlWidgetButton(action: OpenOpentifyTunerIntent()) {
        Label("Ladička", systemImage: "tuningfork")
      }
    }
    .displayName("Ladička")
    .description("Ladička na kytaru v Opentify.")
  }
}

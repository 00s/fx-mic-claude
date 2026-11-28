import AppKit
import SwiftUI

@MainActor func png(_ view: some View, _ out: String, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view); r.scale = scale
    guard let img = r.cgImage else { print("render failed \(out)"); return }
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}

@MainActor func island(_ s: ColorScheme, _ set: (HUDModel) -> Void) -> some View {
    let m = HUDModel(); m.shown = true; m.showMeter = false; set(m)
    return IslandStack(model: m) { EmptyView() }.environment(\.onSheet, true).environment(\.colorScheme, s)
}

@MainActor func docs(_ dir: String) {
    let words = "Let's add a dark mode toggle to the settings page, next to the font size"
    for s in [ColorScheme.light, .dark] {
        let ink = Ink.of(s), bg = s == .dark ? Color(white: 0.13) : Color(white: 0.96), name = s == .dark ? "dark" : "light"
        // The island while squeezing, and the states around it.
        let listening = island(s) { m in m.title = "Listening"; m.tint = .yellow; m.icon = "mic.fill"; m.showMeter = true; m.level = -22
            m.body = words; m.footer = "Settings redesign" }
        let small: [(HUDModel) -> Void] = [
            { m in m.title = "Starting…"; m.tint = .gray; m.icon = "mic" },
            { m in m.title = "Listening"; m.tint = .yellow; m.icon = "mic.fill"; m.intent = "Queue"; m.showMeter = true; m.level = -30 },
            { m in m.title = "Listening"; m.tint = .yellow; m.icon = "mic.fill"; m.intent = "Draft"; m.showMeter = true; m.level = -30 },
            { m in m.title = "Sent"; m.tint = .green; m.icon = "checkmark.circle.fill" },
            { m in m.title = "Nothing to send"; m.tint = .gray; m.icon = "waveform.slash" },
            { m in m.title = "Canceled"; m.tint = .gray; m.icon = "xmark.circle" },
        ]
        let order = [0, 3, 1, 4, 2, 5]   // Starting, Sent / Queue, Nothing to send / Draft, Canceled
        let states = VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 16) {
                    // Room around each pill: Queue and Draft grow a little with their level glow, so a crop at the pill's own
                    // size would cut their ends. The crop still stops above the rail.
                    ForEach(0..<2, id: \.self) { c in
                        island(s, small[order[r * 2 + c]]).padding(.horizontal, 10).padding(.top, 4)
                            .frame(height: 64, alignment: .top).clipped()
                    }
                }
            }
        }
        .padding(28).background(bg).foregroundStyle(ink.primary).font(.ui(14))
        png(states, "\(dir)/states-\(name).png")
        // The gestures: while squeezing, and with the handle released.
        let line = ink.secondary
        let squeezeRail = ActionRail(items: [
            RailItem("Release\nto send") { MicButtonGlyph(pressed: MicButtonGlyph.squeeze, line: line, pull: 0.5) },
            RailItem("Top to\nqueue") { MicButtonGlyph(pressed: 0, line: line) },
            RailItem("Middle\nto draft") { MicButtonGlyph(pressed: 1, line: line) },
            RailItem("Shake to\ncancel") { MicButtonGlyph(pressed: MicButtonGlyph.shake, line: line) },
        ], selected: nil)
        let releasedRail = ActionRail(items: [
            RailItem("Bottom opens\npanel") { MicButtonGlyph(pressed: 2, line: line) },
            RailItem("Twice to\nmute") { MicButtonGlyph(pressed: 2, line: line) },
            RailItem("Hold top\nfor Claude") { MicButtonGlyph(pressed: 0, line: line) },
            RailItem("Hold middle\nfor K.O. II") { MicButtonGlyph(pressed: 1, line: line) },
        ], selected: nil)
        let rails = VStack(alignment: .leading, spacing: 10) {
            Text("While squeezing").font(.mono(12, .semibold)).foregroundStyle(ink.secondary).padding(.leading, 12)
            squeezeRail.frame(width: 420)
            Text("Handle released").font(.mono(12, .semibold)).foregroundStyle(ink.secondary).padding(.leading, 12).padding(.top, 8)
            releasedRail.frame(width: 420)
        }
        .environment(\.onSheet, true).environment(\.colorScheme, s)
        .padding(28).background(bg).foregroundStyle(ink.primary).font(.ui(14))
        png(rails, "\(dir)/gestures-\(name).png")
        png(howItWorks(s), "\(dir)/how-\(name).png")
    }
    // Gesture demos as frames, for GIFs: the mic acting out each gesture beside what it does on the Mac.
    for g in [MicGesture.send, .queue, .draft, .cancel] {
        let fps = 12.0, n = Int(g.demoSeconds * fps)
        let dirG = "\(dir)/frames-\(g)"
        try? FileManager.default.createDirectory(atPath: dirG, withIntermediateDirectories: true)
        for i in 0..<n {
            let v = MicDemo(chosen: g, ink: Ink.of(.light), live: LiveMic(), island: HUDModel(), at: Double(i) / fps)
                .frame(width: 340, height: 240).padding(.vertical, 12).background(Color(white: 0.96))
                .environment(\.colorScheme, .light)
            png(v, String(format: "%@/%04d.png", dirG, i), scale: 1.5)
        }
    }
    print("docs rendered")
}

// MARK: hero: a laptop showing Claude and the island, the mic beside it, on a transparent background.

/// The screen: a soft wallpaper, a menu bar, a lo-fi Claude window with the words arriving in its composer, and the
/// floating island at the top, as it looks while squeezing.
@MainActor struct HeroScreen: View {
    let words: String
    var body: some View {
        let ink = Ink.of(.light)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.93, green: 0.88, blue: 0.82), Color(red: 0.80, green: 0.86, blue: 0.93)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar, with Squeeze's mic in it.
            HStack(spacing: 14) {
                Spacer()
                MicButtonGlyph(pressed: MicButtonGlyph.none, line: Color.black.opacity(0.85), side: 15, solid: true)
                    .frame(width: 15, height: 15)
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(Color.black.opacity(0.55)).frame(width: 14, height: 6) }
                Capsule().fill(Color.black.opacity(0.55)).frame(width: 40, height: 6)
            }
            .padding(.horizontal, 16).frame(height: 24).background(Color.white.opacity(0.35))
            // Claude's window.
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach([0.8, 0.6, 0.7, 0.5, 0.65], id: \.self) { w in
                        Capsule().fill(Color.black.opacity(0.10)).frame(width: 150 * w, height: 8)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, 58).frame(width: 190).frame(maxHeight: .infinity, alignment: .top)
                .background(Color(white: 0.965))
                VStack(alignment: .leading, spacing: 14) {
                    Spacer().frame(height: 40)
                    HStack { Spacer(); Capsule().fill(Color(red: 0.90, green: 0.91, blue: 0.95)).frame(width: 260, height: 34) }
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach([0.95, 0.88, 0.92, 0.6], id: \.self) { w in Capsule().fill(Color.black.opacity(0.09)).frame(width: 420 * w, height: 8) }
                    }
                    HStack { Spacer(); Capsule().fill(Color(red: 0.90, green: 0.91, blue: 0.95)).frame(width: 190, height: 34) }
                    Spacer()
                    // The composer, where the words arrive.
                    HStack(alignment: .center) {
                        Text(words).font(.ui(15)).foregroundStyle(ink.primary)
                            + Text("|").font(.ui(15, .light)).foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                        Spacer()
                        Circle().fill(Color(red: 0.85, green: 0.47, blue: 0.34)).frame(width: 28, height: 28)
                            .overlay(Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                    }
                    .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.black.opacity(0.10)))
                }
                .padding(.horizontal, 36).padding(.bottom, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.white)
            }
            // The window controls where macOS puts them: 12 pt across, 20 pt apart, centred 20 pt in from the corner.
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1.0, green: 0.37, blue: 0.34), Color(red: 1.0, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) { c in
                        Circle().fill(c).frame(width: 12, height: 12)
                    }
                }
                .padding(.leading, 14).padding(.top, 14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .padding(.top, 70).padding(.horizontal, 70).padding(.bottom, 40)
            // The island, floating at the top of the screen.
            heroIsland(words).padding(.top, 34)
        }
    }
}

@MainActor func heroIsland(_ words: String) -> some View {
    let m = HUDModel(); m.shown = true; m.title = "Listening"; m.tint = .yellow; m.icon = "mic.fill"
    // The same glow as the Queue and Draft pills in the states image, a little lower: yellow reads stronger.
    m.showMeter = true; m.level = -46; m.body = words; m.footer = "Settings redesign"
    return IslandStack(model: m) { EmptyView() }
        .environment(\.onSheet, true).environment(\.colorScheme, .light)
        .foregroundStyle(Ink.of(.light).primary).font(.ui(14))
        // Over the screen, each piece reads as frosted glass.
        .environment(\.sheetFill, Color.white.opacity(0.86))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
}

@MainActor func heroImage(_ out: String) {
    let words = "Let's add a dark mode toggle to the settings page"
    let screenW = 1080.0, screenH = 680.0
    let laptop = VStack(spacing: 0) {
        // Lid: a thin dark bezel around the screen.
        HeroScreen(words: words).frame(width: screenW, height: screenH)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color(white: 0.45), lineWidth: 1.5))
        // Base: aluminium, wider than the lid, with the opening notch.
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 3, bottomLeading: 22, bottomTrailing: 22, topTrailing: 3), style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.70)], startPoint: .top, endPoint: .bottom))
                .frame(width: screenW + 32 + 150, height: 24)
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 8, bottomTrailing: 8, topTrailing: 0))
                .fill(Color(white: 0.62)).frame(width: 150, height: 9)
        }
    }
    let micDemo = MicDemo(chosen: .send, ink: Ink.of(.light), live: LiveMic(), island: HUDModel())
    let mic = micDemo.mic(t: 0.4, squeeze: 1, press: 0, button: -1, shaking: false, level: 6, sweepY: 519.8)
        .frame(width: 250, height: 330)
        .rotationEffect(.degrees(-9))
        .shadow(color: .black.opacity(0.28), radius: 18, x: 6, y: 14)
    let scene = ZStack(alignment: .bottomTrailing) {
        laptop.padding(.trailing, 150).padding(.bottom, 10)
        mic.offset(x: -10, y: 0)
    }
    .padding(40)
    let r = ImageRenderer(content: scene); r.scale = 2
    guard let img = r.cgImage else { print("hero failed"); return }
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("hero written")
}


// MARK: how it works: three steps, left to right, in the rails' style.

@MainActor func howItWorks(_ s: ColorScheme) -> some View {
    let ink = Ink.of(s), line = ink.secondary
    let fill = ink.primary.opacity(0.07)
    func step(_ n: String, _ title: String, _ detail: String, @ViewBuilder _ art: () -> some View) -> some View {
        VStack(spacing: 14) {
            art().frame(height: 64)
            VStack(spacing: 4) {
                Text(title).font(.ui(15, .semibold)).foregroundStyle(ink.primary)
                Text(detail).font(.ui(13)).foregroundStyle(ink.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 22).padding(.horizontal, 14).frame(width: 220, height: 190)
        .background(RoundedRectangle(cornerRadius: Metric.card, style: .continuous).fill(fill))
    }
    let arrow = Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(line.opacity(0.7))
    let yellow = s == .dark ? Color.yellow : Color(.sRGB, red: 0.80, green: 0.60, blue: 0.0, opacity: 1)
    return HStack(spacing: 14) {
        step("1", "You squeeze", "The mic marks it with a tone, or over USB") {
            MicButtonGlyph(pressed: MicButtonGlyph.squeeze, line: line, side: 64, pull: 0.6).frame(width: 64, height: 64)
        }
        arrow
        step("2", "The app listens", "Apple's recognizer or Claude's dictation writes the words") {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 18, weight: .medium)).foregroundStyle(yellow)
                Text("Listening").font(.ui(16, .semibold)).foregroundStyle(ink.primary)
            }
            .padding(.horizontal, 18).frame(height: 44)
            .background(Capsule().fill(yellow.opacity(0.22)))
        }
        arrow
        step("3", "Claude gets it", "Typed into the composer and sent as your message") {
            HStack(spacing: 10) {
                Capsule().fill(ink.secondary.opacity(0.35)).frame(width: 96, height: 8)
                Circle().fill(Color(red: 0.85, green: 0.47, blue: 0.34)).frame(width: 26, height: 26)
                    .overlay(Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            }
            .padding(.leading, 16).padding(.trailing, 9).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ink.secondary.opacity(0.35)))
        }
    }
    .padding(28).background(s == .dark ? Color(white: 0.13) : Color(white: 0.96))
}

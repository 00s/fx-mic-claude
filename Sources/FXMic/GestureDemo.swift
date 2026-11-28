import AppKit
import SwiftUI

/// One beat of a gesture tutorial: what the caption says, for how long, and what the mic does meanwhile. Every beat
/// lasts at least a second, so each caption can be read.
struct DemoStep {
    let label: String
    let icon: String
    let seconds: Double
    var squeeze = false
    var speaking = false
    var shake = false
    var outcome = false
    var sweep = false
    var button: Int? = nil
    var presses = 1
    var hold = false
}

extension MicGesture {
    /// The tutorial, beat by beat.
    var steps: [DemoStep] {
        let squeeze = DemoStep(label: "Squeeze", icon: "arrow.right.and.line.vertical.and.arrow.left", seconds: 1.2, squeeze: true)
        func listen(_ s: Double) -> DemoStep { DemoStep(label: "Listening", icon: "waveform", seconds: s, squeeze: true, speaking: true) }
        let letGo = DemoStep(label: "Let go", icon: "arrow.left.and.line.vertical.and.arrow.right", seconds: 1.1)
        switch self {
        case .talk:
            return [squeeze, listen(2.6), letGo]
        case .send:
            return [squeeze, listen(2.4), letGo, DemoStep(label: "Sent", icon: "paperplane.fill", seconds: 1.8, outcome: true)]
        case .queue, .draft:
            let top = self == .queue
            return [squeeze, listen(1.6),
                    DemoStep(label: top ? "Press top" : "Press middle", icon: "hand.tap.fill", seconds: 1.3,
                             squeeze: true, speaking: true, button: top ? 0 : 1),
                    letGo,
                    DemoStep(label: top ? "Queued" : "In draft", icon: top ? "clock.fill" : "square.and.pencil",
                             seconds: 1.8, outcome: true)]
        case .cancel:
            return [squeeze, listen(1.6),
                    DemoStep(label: "Shake", icon: "arrow.left.arrow.right", seconds: 1.4, squeeze: true, shake: true),
                    DemoStep(label: "Let go", icon: "arrow.left.and.line.vertical.and.arrow.right", seconds: 1.0),
                    DemoStep(label: "Gone", icon: "xmark.circle.fill", seconds: 1.6, outcome: true)]
        case .show:
            let choice = Settings.shared.bottomButton
            let result = choice == "panel" ? ("Panel opens", "rectangle.topthird.inset.filled")
                : choice == "none" ? ("Nothing happens", "minus.circle")
                : choice == "toggle" ? ("Claude shows or hides", "macwindow") : ("Claude comes forward", "macwindow")
            return [DemoStep(label: "Press bottom", icon: "hand.tap.fill", seconds: 1.4, button: 2),
                    DemoStep(label: result.0, icon: result.1, seconds: 2.6, outcome: choice != "none")]
        case .hangUp:
            let twice = DemoStep(label: "Press twice", icon: "hand.tap.fill", seconds: 1.5, button: 2, presses: 2)
            return [twice, DemoStep(label: "Muted", icon: "mic.slash.fill", seconds: 1.9, outcome: true),
                    twice, DemoStep(label: "Mic open", icon: "mic.fill", seconds: 1.9, outcome: true)]
        case .claude, .ko2:
            let top = self == .claude
            return [DemoStep(label: top ? "Hold top" : "Hold middle", icon: "hand.tap.fill", seconds: 3.5,
                             button: top ? 0 : 1, hold: true),
                    DemoStep(label: "Saved", icon: "checkmark", seconds: 1.3, outcome: true, sweep: true),
                    DemoStep(label: "Restart the mic", icon: "arrow.clockwise", seconds: 2.2, outcome: true)]
        }
    }

    var demoSeconds: Double { steps.reduce(0) { $0 + $1.seconds } }
}

/// The mic as drawn in the reference, acting out the chosen gesture beside a lo-fi sketch of what it does on the Mac:
/// the words filling Claude's composer and leaving, the panel dropping from the menu bar, macOS's orange microphone
/// dot going away and coming back, or the app the mic switches to. The caption under them names each beat.
/// Out of focus the whole card goes quiet: the mic in outline, the sketch in grey.
struct MicDemo: View {
    @Environment(\.appearsActive) private var active
    @Environment(\.colorScheme) private var scheme
    let chosen: MicGesture
    let ink: Ink
    @ObservedObject var live: LiveMic
    @ObservedObject var island: HUDModel
    @State private var started = Date()

    func hex(_ h: UInt32) -> Color {
        Color(.sRGB, red: Double(h >> 16 & 255) / 255, green: Double(h >> 8 & 255) / 255, blue: Double(h & 255) / 255, opacity: 1)
    }

    /// 0 to 1 over 0.14 s from `from`, back to 0 by `to`.
    func ramp(_ t: Double, _ from: Double, _ to: Double) -> Double {
        max(0, min(1, (t - from) / 0.14)) * max(0, min(1, (to - t) / 0.14))
    }

    static func ease(_ x: Double) -> Double { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let isLive = live.busy(at: now)
            let steps = chosen.steps
            let t = max(0, now.timeIntervalSince(started)).truncatingRemainder(dividingBy: chosen.demoSeconds)
            let (index, u) = locate(steps, t)
            let step = steps[index]
            let previous = steps[(index + steps.count - 1) % steps.count]
            let gesture = isLive ? (live.last ?? .talk) : chosen
            // The handle eases from where the last beat left it.
            let demoSqueeze = (previous.squeeze ? 1.0 : 0) + ((step.squeeze ? 1.0 : 0) - (previous.squeeze ? 1.0 : 0)) * Self.ease(u / 0.3)
            let squeeze: Double = isLive ? (live.squeezing ? 1 : 0) : demoSqueeze
            let flashing = live.flashAt.map { now.timeIntervalSince($0) < 0.45 } ?? false
            let demoPress: Double = step.button == nil ? 0
                : step.hold ? ramp(u, 0.15, step.seconds - 0.05)
                : (0..<step.presses).map { ramp(u, 0.3 + Double($0) * 0.45, 0.3 + Double($0) * 0.45 + 0.3) }.max() ?? 0
            let press: Double = isLive ? (flashing ? 1 : 0) : demoPress
            let button = isLive ? (flashing ? live.button : -1) : step.button ?? -1
            let shaking = isLive ? (live.shakeAt.map { now.timeIntervalSince($0) < 0.8 } ?? false)
                : step.shake && u > 0.15 && u < step.seconds - 0.25
            let speaking = isLive ? live.squeezing : step.speaking && !shaking
            // After the 3 s hold the sample LEDs confirm: sweeping down for K.O. II, up for Claude.
            let sweeping = !isLive && step.sweep
            let beat = Int(u / 0.11) % 4
            let sweepY = sweeping ? 425.0 + Double(gesture == .ko2 ? beat : 3 - beat) * 46 : 517
            let loudness = Double(max(0, min(1, (island.level + 60) / 54)))
            let level = !speaking ? 0 : isLive ? loudness * 10 : 1.5 + abs(sin(t * 7)) * 4 + abs(sin(t * 17)) * 1.5
            let caption = isLive ? gesture.label
                : step.hold && u > 0.3 ? "Hold… \(min(3, Int(u - 0.3) + 1)) s" : step.label
            let done = !isLive && step.outcome
            VStack(spacing: 14) {
                HStack(spacing: 18) {
                    mic(t: t, squeeze: squeeze, press: press, button: button, shaking: shaking, level: level, sweepY: sweepY)
                        .frame(width: 132, height: 172)
                    DemoScene(gesture: gesture, steps: steps, index: isLive ? nil : index, u: u, t: t,
                              listening: isLive && live.squeezing, words: isLive ? min(1, Double(island.body.count) / 60) : nil,
                              ink: ink, scheme: scheme)
                        .frame(width: 176, height: 172)
                        .saturation(active ? 1 : 0)
                        .opacity(active ? 1 : 0.55)
                }
                Label(caption, systemImage: isLive ? "waveform" : step.icon)
                    .font(.ui(14, .semibold))
                    .foregroundStyle(active ? ink.primary : ink.secondary)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(Capsule().fill(done && active ? ink.accent.opacity(0.18) : ink.hover))
                    .scaleEffect(done ? 1.05 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: done)
                    .animation(.easeInOut(duration: 0.18), value: caption)
            }
            .frame(maxWidth: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: active)
    }

    /// Which beat `t` falls in, and how far into it.
    func locate(_ steps: [DemoStep], _ t: Double) -> (Int, Double) {
        var start = 0.0
        for (i, step) in steps.enumerated() {
            if t < start + step.seconds { return (i, t - start) }
            start += step.seconds
        }
        return (steps.count - 1, steps.last?.seconds ?? 0)
    }

    /// The mic, in its colors, or (out of focus) in one quiet outline.
    func mic(t: Double, squeeze: Double, press: Double, button: Int, shaking: Bool, level: Double, sweepY: Double) -> some View {
        let outline = !active
        let lineColor = ink.secondary
        return Canvas { g, size in
            // Reference coordinates: the drawing spans x 140...1120, y 70...1365.
            let k = min(size.width / 980, size.height / 1295)
            g.translateBy(x: (size.width - 980 * k) / 2, y: (size.height - 1295 * k) / 2)
            g.scaleBy(x: k, y: k)
            g.translateBy(x: -140, y: -70)
            if shaking {
                g.translateBy(x: 695, y: 610)
                g.rotate(by: .degrees(sin(t * 40) * 7))
                g.translateBy(x: -695, y: -610)
            }
            let hair = 1.2 / k                                   // a 1.2 pt line at any size
            func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
                Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
            }
            func dot(_ x: Double, _ y: Double, _ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            /// Filled in its color with an optional edge, or only outlined.
            func paint(_ path: Path, _ fill: Color, edge: Color? = nil) {
                if outline {
                    g.stroke(path, with: .color(lineColor), lineWidth: hair)
                } else {
                    g.fill(path, with: .color(fill))
                    if let edge { g.stroke(path, with: .color(edge), lineWidth: 4) }
                }
            }
            // Handle, swinging in toward the body when squeezed.
            let pull = squeeze * 44
            var handle = Path()
            handle.move(to: CGPoint(x: 244 + pull, y: 212 - squeeze * 8))
            handle.addLine(to: CGPoint(x: 326, y: 183))
            handle.addLine(to: CGPoint(x: 326, y: 712))
            handle.addLine(to: CGPoint(x: 303 + pull * 0.4, y: 710))
            handle.closeSubpath()
            paint(handle, hex(0xEB6133))
            // Cable
            paint(rect(629, 1140, 12, 221, 2), hex(0x9E9E9E))
            for i in 0..<5 { paint(rect(600, 1161 + Double(i) * 32, 71, 20, 10), hex(0x9E9E9E)) }
            // Side buttons, pushed in when pressed
            let buttons: [(Double, Double, UInt32, UInt32)] =
                [(1056, 161, 0xE9805A, 0xB4603F), (1067, 417, 0xF6F6F4, 0xBDBDBB), (1067, 857, 0xDADAD7, 0xB0B0AE)]
            for (i, b) in buttons.enumerated() {
                let inset = i == button ? press * 24 : 0
                let w = i == 0 ? 34.0 : 48.0
                let shape = rect(b.0 - inset, b.1, w, i == 0 ? 111 : 112, 18)
                paint(shape, hex(b.2), edge: hex(b.3))
                if i == button && press > 0 {
                    g.stroke(rect(b.0 - inset - 16, b.1 - 16, w + 32, 144, 28),
                             with: .color((outline ? lineColor : hex(0xEB6133)).opacity(press)), lineWidth: outline ? hair * 2 : 10)
                }
            }
            // Body and speaker panel
            paint(rect(323, 73, 744, 1071, 22), hex(0xF2F2F0), edge: hex(0xCCCCCA))
            paint(Path(roundedRect: CGRect(x: 323, y: 73, width: 744, height: 583),
                       cornerRadii: .init(topLeading: 22, bottomLeading: 18, bottomTrailing: 18, topTrailing: 22)),
                  hex(0x787878))
            // Speaker dots: they darken from the top with the voice, like the reference's level.
            for row in 0..<10 {
                let lit = Double(row) < level
                let fill: Color = Double(row) < level.rounded(.down) ? hex(0x404040) : lit ? hex(0x757572) : hex(0xCDC9BC)
                for col in 0..<11 {
                    let hole = dot(389 + Double(col) * 50.4, 139 + Double(row) * 54.4, 18)
                    if outline {
                        if lit { g.fill(hole, with: .color(lineColor)) } else { g.stroke(hole, with: .color(lineColor.opacity(0.6)), lineWidth: hair) }
                    } else {
                        g.fill(hole, with: .color(fill))
                    }
                }
            }
            // The two LED strips
            for (top, lit, color) in [(137.0, 215.0, hex(0xEE4230)), (393.0, sweepY, Color.white)] {
                paint(rect(971, top, 48, 215, 24), hex(0x5C5C5C))
                for i in 0..<4 {
                    let y = top + 32 + Double(i) * 46
                    let on = abs(y - lit) < 8
                    if outline {
                        if on { g.fill(dot(995, y, 12), with: .color(lineColor)) } else { g.stroke(dot(995, y, 12), with: .color(lineColor), lineWidth: hair) }
                    } else {
                        if on { g.fill(dot(995, y, 27), with: .color(color.opacity(0.28))) }
                        g.fill(dot(995, y, 12), with: .color(on ? color : hex(0x8A8A8A)))
                    }
                }
            }
            // Screws
            for (x, y) in [(387.0, 721.0), (1002.0, 721.0), (387.0, 1081.0), (1002.0, 1081.0)] {
                g.stroke(dot(x, y, 25), with: .color(outline ? lineColor : hex(0xCCCCCA)), lineWidth: outline ? hair : 4)
            }
        }
        .accessibilityLabel("The mic")
    }
}

/// The lo-fi Mac side of a tutorial, drawn in a 176 x 172 space: nothing here is a screenshot or anyone's artwork.
struct DemoScene: View {
    let gesture: MicGesture
    let steps: [DemoStep]
    /// The beat, nil while the real mic is in use.
    let index: Int?
    let u: Double
    let t: Double
    /// The real mic, squeezed right now, and how much it has said (0 to 1).
    let listening: Bool
    let words: Double?
    let ink: Ink
    let scheme: ColorScheme

    private static func ease(_ x: Double) -> Double { MicDemo.ease(x) }

    private var window: Color { scheme == .dark ? Color(white: 0.20) : Color(white: 0.99) }
    private var bar: Color { ink.secondary.opacity(scheme == .dark ? 0.45 : 0.28) }
    private var edge: Color { ink.secondary.opacity(0.45) }
    private var mine: Color { ink.accent.opacity(scheme == .dark ? 0.55 : 0.35) }
    private let orange = Color(.sRGB, red: 1, green: 0.62, blue: 0.04, opacity: 1)       // macOS's microphone dot
    private let claude = Color(.sRGB, red: 0.85, green: 0.47, blue: 0.34, opacity: 1)

    var body: some View {
        Canvas { g, size in
            let k = min(size.width / 176, size.height / 172)
            g.translateBy(x: (size.width - 176 * k) / 2, y: (size.height - 172 * k) / 2)
            g.scaleBy(x: k, y: k)
            switch gesture {
            case .talk, .send, .queue, .draft, .cancel: chat(&g)
            case .show: Settings.shared.bottomButton == "panel" ? panel(&g) : front(&g)
            case .hangUp: menuBar(&g)
            case .claude, .ko2: app(&g)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: helpers

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
    }
    private func dot(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    private func symbol(_ g: inout GraphicsContext, _ name: String, _ x: Double, _ y: Double, _ size: Double, _ color: Color) {
        g.draw(Text(Image(systemName: name)).font(.system(size: size, weight: .semibold)).foregroundStyle(color), at: CGPoint(x: x, y: y))
    }
    private func caption(_ g: inout GraphicsContext, _ s: String, _ x: Double, _ y: Double, _ size: Double, _ color: Color) {
        g.draw(Text(s).font(.ui(size, .semibold)).foregroundStyle(color), at: CGPoint(x: x, y: y))
    }
    /// A window: frame, title bar dots, and the shape to draw into.
    private func windowFrame(_ g: inout GraphicsContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double, alpha: Double = 1) {
        g.fill(rect(x, y, w, h, 12), with: .color(window.opacity(alpha)))
        g.stroke(rect(x, y, w, h, 12), with: .color(edge.opacity(alpha)), lineWidth: 1)
        for i in 0..<3 { g.fill(dot(x + 12 + Double(i) * 9, y + 11, 2.6), with: .color(bar.opacity(alpha))) }
    }
    /// The beat named `label` has been reached (and how far into it, 0 to 1 over `over` seconds); nil before it.
    private func reached(_ label: String, over: Double = 0.5) -> Double? {
        guard let index else { return nil }
        guard let at = steps.firstIndex(where: { $0.label == label }), index >= at else { return nil }
        return index == at ? Self.ease(u / over) : 1
    }
    /// Seconds spoken so far in this loop, for how much of the composer is filled.
    private var spoken: Double {
        guard let index else { return 0 }
        let before = steps.prefix(index).filter(\.speaking).reduce(0) { $0 + $1.seconds }
        return before + (steps[index].speaking ? u : 0)
    }

    // MARK: scenes

    /// Claude's window: a thread above, the composer below. The words fill the composer while you talk; letting go
    /// sends them up into the thread, keeps them waiting with a clock (queue), leaves them in the composer (draft),
    /// or a shake drops them.
    private func chat(_ g: inout GraphicsContext) {
        windowFrame(&g, 6, 8, 164, 158)
        g.fill(rect(18, 30, 84, 13, 6.5), with: .color(bar))
        g.fill(rect(74, 50, 84, 13, 6.5), with: .color(mine))
        g.fill(rect(18, 70, 66, 13, 6.5), with: .color(bar))
        // Composer
        g.stroke(rect(14, 130, 148, 28, 10), with: .color(edge), lineWidth: 1)
        let fill = words ?? min(1, spoken / 2.2)
        let sentAt = gesture == .send || gesture == .queue ? reached("Let go", over: 0.6) : nil
        let gone = gesture == .cancel ? reached("Shake", over: 0.9) : nil
        let chunks: [Double] = [16, 24, 12, 20, 28, 14]
        let total = chunks.reduce(0, +) + Double(chunks.count - 1) * 4
        // Where the message sits: in the composer, on its way, or in the thread.
        let move = sentAt ?? 0
        let x0 = 22 + (156 - total - 22 - 4) * move
        let y0 = 140 - (140 - 94) * move
        if move > 0 {
            let bubble = rect(x0 - 6, y0 - 3, total + 12, 14, 7)
            if gesture == .queue {
                g.stroke(bubble, with: .color(ink.accent.opacity(move)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                symbol(&g, "clock.fill", x0 - 14, y0 + 4, 10, ink.accent.opacity(move))
            } else {
                g.fill(bubble, with: .color(mine.opacity(move)))
            }
        }
        var x = x0
        for c in chunks {
            let visible = max(0, min(1, (fill * total - (x - x0)) / c))
            if visible > 0 {
                g.fill(rect(x, y0, c * visible, 8, 4), with: .color(ink.secondary.opacity((1 - (gone ?? 0)) * 0.8)))
            }
            x += c + 4
        }
        // A blinking caret until the first word.
        if fill < 0.02 && (index.map { steps[$0].squeeze } ?? listening) && Int(t * 2.5) % 2 == 0 {
            g.fill(rect(22, 137, 1.5, 14, 0.75), with: .color(ink.accent))
        }
        // What the buttons did, on the composer's right end.
        if gesture == .draft, let p = reached("Press middle", over: 0.3) {
            symbol(&g, "square.and.pencil", 148, 144, 11 * p, ink.accent)
        } else if gesture == .queue, let p = reached("Press top", over: 0.3), move == 0 {
            symbol(&g, "clock.fill", 148, 144, 11 * p, ink.accent)
        } else {
            g.fill(dot(149, 144, 7), with: .color(fill > 0.05 && gone == nil ? ink.accent : bar))
            symbol(&g, "arrow.up", 149, 144, 8, .white)
        }
    }

    /// The menu bar with the panel dropping from its icon.
    private func panel(_ g: inout GraphicsContext) {
        let p = reached(steps.last?.label ?? "", over: 0.45) ?? 0
        g.fill(rect(0, 4, 176, 16, 5), with: .color(bar.opacity(0.7)))
        for (i, x) in [112.0, 136, 156].enumerated() {
            g.fill(rect(x, 8, i == 0 ? 14 : 10, 8, 2.5), with: .color(i == 0 && p > 0 ? ink.accent : ink.secondary.opacity(0.55)))
        }
        guard p > 0 else { return }
        var drop = g
        drop.opacity = p
        drop.translateBy(x: 0, y: -16 * (1 - p))
        drop.fill(rect(64, 26, 108, 140, 16), with: .color(window))
        drop.stroke(rect(64, 26, 108, 140, 16), with: .color(edge), lineWidth: 1)
        drop.fill(rect(71, 33, 94, 18, 9), with: .color(bar))
        for i in 0..<3 { drop.fill(rect(71 + Double(i) * 32, 56, 30, 14, 7), with: .color(i == 1 ? mine : bar)) }
        drop.stroke(rect(71, 76, 94, 82, 11), with: .color(edge), lineWidth: 1)
        for i in 0..<3 { drop.fill(rect(79, 86 + Double(i) * 22, i == 1 ? 60 : 72, 9, 4.5), with: .color(bar)) }
    }

    /// Claude's window coming forward over another one.
    private func front(_ g: inout GraphicsContext) {
        let p = reached(steps.last?.label ?? "", over: 0.5) ?? 0
        let nothing = Settings.shared.bottomButton == "none"
        windowFrame(&g, 6, 10, 132, 104, alpha: 0.9)
        guard !nothing else {
            symbol(&g, "minus.circle", 120, 128, 22, ink.secondary.opacity(0.6))
            return
        }
        var w = g
        w.opacity = 0.35 + 0.65 * p
        w.translateBy(x: 0, y: 16 * (1 - p))
        windowFrame(&w, 34, 40, 136, 120)
        w.fill(rect(46, 132, 112, 18, 8), with: .color(bar))
        if let mark = ClaudeMark.image {
            var image = w.resolve(Image(nsImage: mark).renderingMode(.template))
            image.shading = .color(claude)
            w.draw(image, in: CGRect(x: 86, y: 70, width: 34, height: 34))
        } else {
            symbol(&w, "bubble.left.fill", 103, 87, 26, claude)
        }
    }

    /// A close-up of the menu bar: macOS's orange dot shows while the mic is open, and goes when it is muted.
    private func menuBar(_ g: inout GraphicsContext) {
        guard let index else { return }
        let label = steps[index].label
        let open: Double = label == "Muted" ? 1 - Self.ease(u / 0.35)
            : label == "Mic open" ? Self.ease(u / 0.35)
            : index < 2 ? 1 : 0
        let pop = label == "Mic open" ? 1 + 0.5 * sin(.pi * min(1, u / 0.45)) : 1
        g.fill(rect(4, 62, 168, 30, 9), with: .color(bar.opacity(0.6)))
        g.stroke(rect(4, 62, 168, 30, 9), with: .color(edge), lineWidth: 1)
        // This app's icon, then the system's: control center, wifi, clock.
        symbol(&g, open > 0.5 ? "mic.fill" : "mic.slash.fill", 52, 77, 13, ink.primary)
        symbol(&g, "switch.2", 100, 77, 12, ink.secondary)
        symbol(&g, "wifi", 122, 77, 12, ink.secondary)
        caption(&g, "9:41", 151, 77, 12, ink.secondary)
        if open > 0 {
            g.fill(dot(78, 77, 9 * open * pop), with: .color(orange.opacity(0.25 * open)))
            g.fill(dot(78, 77, 4.5 * open * pop), with: .color(orange.opacity(open)))
        }
        caption(&g, open > 0.5 ? "Mic in use" : "Mic closed", 78, 112, 12, open > 0.5 ? orange : ink.secondary)
    }

    /// The app the mic switches to: Claude, or the K.O. II sampler, filling in as the hold counts to three.
    private func app(_ g: inout GraphicsContext) {
        guard let index else { return }
        let held = index == 0 ? min(1, max(0, (u - 0.3) / 3)) : 1
        let saved = index > 0
        let cx = 88.0, cy = 74.0
        // The hold, as a ring that closes at 3 s.
        var ring = Path()
        ring.addArc(center: CGPoint(x: cx, y: cy), radius: 52, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * held), clockwise: false)
        g.stroke(Path(ellipseIn: CGRect(x: cx - 52, y: cy - 52, width: 104, height: 104)), with: .color(bar), lineWidth: 3)
        g.stroke(ring, with: .color(saved ? ink.accent : ink.secondary), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        var tile = g
        tile.opacity = 0.3 + 0.7 * held
        if gesture == .claude {
            tile.fill(rect(cx - 34, cy - 34, 68, 68, 16), with: .color(claude))
            if let mark = ClaudeMark.image {
                var image = tile.resolve(Image(nsImage: mark).renderingMode(.template))
                image.shading = .color(.white)
                tile.draw(image, in: CGRect(x: cx - 20, y: cy - 20, width: 40, height: 40))
            }
        } else {
            // A lo-fi sampler: a slab with a small screen, two knobs and a grid of pads.
            let body = rect(cx - 30, cy - 38, 60, 76, 5)
            tile.fill(body, with: .color(scheme == .dark ? Color(white: 0.55) : Color(white: 0.86)))
            tile.stroke(body, with: .color(edge), lineWidth: 1)
            tile.fill(rect(cx - 24, cy - 32, 24, 12, 2), with: .color(Color(white: 0.2)))
            for x in [cx + 10, cx + 21] { tile.fill(dot(x, cy - 26, 4), with: .color(Color(white: 0.35))) }
            for row in 0..<4 {
                for col in 0..<3 {
                    let pad = rect(cx - 22 + Double(col) * 16, cy - 12 + Double(row) * 12.5, 12, 9.5, 2)
                    tile.fill(pad, with: .color(row == 3 && col == 2 ? orange : Color(white: scheme == .dark ? 0.8 : 0.97)))
                }
            }
        }
        if saved {
            let p = index == 1 ? Self.ease(u / 0.3) : 1
            g.fill(dot(cx + 30, cy - 30, 10 * p), with: .color(ink.accent))
            symbol(&g, index == 1 ? "checkmark" : "arrow.clockwise", cx + 30, cy - 30, 10 * p, .white)
        }
        caption(&g, gesture == .claude ? "Claude mode" : "K.O. II mode", cx, 150, 13, saved ? ink.primary : ink.secondary)
    }
}

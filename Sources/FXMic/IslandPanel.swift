import AppKit
import FXMicCore
import ServiceManagement
import SwiftUI

/// The panel under the menu bar icon: what the island shows, live, with the transcript; below it, where messages go,
/// the mic gestures (the drawing follows the real mic) and the settings. Liquid Glass; it never activates FXMic.

/// What the mic is doing, as FXMic hears it. Mode switches happen inside the mic and are not reported.
final class LiveMic: ObservableObject {
    @Published var state = AppController.State.idle
    @Published var usb = false                // the mic reports squeezes over USB
    @Published var squeezing = false
    @Published var last: MicGesture?
    @Published var button = -1                // 0 top, 1 middle, 2 bottom
    @Published var flashAt: Date?
    @Published var shakeAt: Date?
    private var activeAt = Date.distantPast
    private var canceled = false

    /// True while the mic is in use and for a moment after, so the drawing shows the real thing, not the demo.
    func busy(at now: Date) -> Bool { squeezing || now.timeIntervalSince(activeAt) < 2.5 }

    func squeeze(_ on: Bool) {
        squeezing = on
        activeAt = Date()
        if on { canceled = false; last = .talk } else if !canceled { last = last == .queue || last == .draft ? last : .send }
    }
    func press(_ index: Int) {
        button = index
        flashAt = Date()
        activeAt = Date()
        last = index == 0 ? .queue : index == 1 ? .draft : .show
    }
    func shake() { canceled = true; shakeAt = Date(); activeAt = Date(); last = .cancel }
}

// One set of ink colors per appearance; text never relies on vibrancy or opacity.
struct Ink {
    let primary, secondary, accent, live, danger, wash, hover, dense: Color
    static func of(_ s: ColorScheme) -> Ink {
        func c(_ h: UInt32, _ a: Double = 1) -> Color {
            Color(.sRGB, red: Double(h >> 16 & 255) / 255, green: Double(h >> 8 & 255) / 255, blue: Double(h & 255) / 255, opacity: a)
        }
        return s == .dark
            ? Ink(primary: c(0xF5F5F7), secondary: c(0xC7C7CC), accent: c(0x93B4FF), live: c(0xFBBF24), danger: c(0xC62828),
                  wash: c(0x1C1C1E, 0.28), hover: c(0xFFFFFF, 0.10), dense: c(0x1C1C1E, 0.30))
            : Ink(primary: c(0x111113), secondary: c(0x46464B), accent: c(0x1D4ED8), live: c(0xA24E06), danger: c(0xC4261D),
                  wash: c(0xFFFFFF, 0.38), hover: c(0x000000, 0.07), dense: c(0xFFFFFF, 0.40))
    }
}

struct PanelRow<Content: View>: View {
    @Environment(\.colorScheme) var scheme
    var selected = false
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var over = false
    var body: some View {
        let ink = Ink.of(scheme)
        Button(action: action) {
            HStack(spacing: 12) { content }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? ink.accent.opacity(0.14) : over ? ink.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { over = $0 }
    }
}

enum MicGesture: CaseIterable {
    case talk, send, cancel, queue, draft, show, ko2, claude, hangUp
    var label: String {
        switch self {
        case .talk: "Squeeze and talk"
        case .send: "Release to send"
        case .cancel: "Shake to cancel"
        case .draft: "Middle for draft"
        case .queue: "Top to queue"
        case .show:
            switch Settings.shared.bottomButton {
            case "claude": "Bottom button brings Claude forward"
            case "toggle": "Bottom button shows or hides Claude"
            case "none": "Bottom button does nothing"
            default: "Bottom button opens this panel"
            }
        case .ko2: "Hold middle for K.O. II"
        case .claude: "Hold top for Claude"
        case .hangUp: "Twice to mute"
        }
    }
    var usesHandle: Bool { self != .show && self != .hangUp && !isModeSwitch }
    var isModeSwitch: Bool { self == .ko2 || self == .claude }
}

/// A pinned conversation: click the row to send there; the filled pin has its own hover circle and turns into an
/// unpin icon under the pointer.
struct PinnedRow: View {
    let title: String
    let selected: Bool
    let ink: Ink
    let select: () -> Void
    let unpin: () -> Void
    @State private var overRow = false
    @State private var overPin = false
    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 12) {
                    ClaudeIcon(size: 22).frame(width: 28)
                    Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").fontWeight(.semibold) }
                }
                .padding(.leading, 12).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: unpin) {
                Image(systemName: overPin ? "pin.slash.fill" : "pin.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(overPin ? ink.danger : ink.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(overPin ? ink.danger.opacity(0.18) : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).onHover { overPin = $0 }.help("Unpin").accessibilityLabel("Unpin \(title)")
            .padding(.trailing, 4)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(selected ? ink.accent.opacity(0.14) : overRow ? ink.hover : .clear))
        .onHover { overRow = $0 }
        .animation(.easeOut(duration: 0.12), value: overPin)
    }
}

/// The mic as drawn in the reference, acting out the chosen gesture: the handle squeezes in, the speaker dots follow
/// the voice, a side button presses, or the whole unit shakes; a bubble says what happens to the words.
struct MicDemo: View {
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

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = max(0, timeline.date.timeIntervalSince(started)).truncatingRemainder(dividingBy: chosen.isModeSwitch ? 5.4 : 2.8)
            // The real mic, while it is being used; otherwise a looping demo of the chosen gesture.
            let now = timeline.date
            let isLive = live.busy(at: now)
            let gesture = isLive ? (live.last ?? .talk) : chosen
            let squeeze: Double = isLive ? (live.squeezing ? 1 : 0) : gesture.usesHandle ? ramp(t, 0.3, gesture == .talk ? 2.65 : 2.0) : 0
            let flashing = live.flashAt.map { now.timeIntervalSince($0) < 0.45 } ?? false
            let press: Double = isLive ? (flashing ? 1 : 0)
                : [MicGesture.queue, .draft].contains(gesture) ? ramp(t, 0.9, 1.35) : gesture == .show ? ramp(t, 0.5, 0.95)
                : gesture.isModeSwitch ? ramp(t, 0.4, 3.4) : gesture == .hangUp ? max(ramp(t, 0.4, 0.75), ramp(t, 0.95, 1.3)) : 0
            let button = isLive ? (flashing ? live.button : -1)
                : gesture == .queue ? 0 : gesture == .draft ? 1 : gesture == .show || gesture == .hangUp ? 2 : gesture == .ko2 ? 1 : gesture == .claude ? 0 : -1
            let shaking = isLive ? (live.shakeAt.map { now.timeIntervalSince($0) < 0.8 } ?? false)
                : gesture == .cancel && t > 1.1 && t < 1.9
            let speaking = isLive ? live.squeezing : squeeze > 0.9 && !shaking
            let done = !isLive && gesture != .talk && t > (gesture == .show ? 0.95 : gesture == .hangUp ? 1.3 : gesture.isModeSwitch ? 3.4 : 2.0)
            // After the 3 s hold the sample LEDs confirm: sweeping down for K.O. II, up for Claude.
            let sweeping = !isLive && gesture.isModeSwitch && t > 3.4
            let step = Int(max(0, t - 3.4) / 0.11) % 4
            let sweepY = sweeping ? 425.0 + Double(gesture == .ko2 ? step : 3 - step) * 46 : 517
            let loudness = Double(max(0, min(1, (island.level + 60) / 54)))
            VStack(spacing: 10) {
                Canvas { g, size in
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
                    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
                        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
                    }
                    func dot(_ x: Double, _ y: Double, _ r: Double) -> Path {
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    }
                    // Handle, swinging in toward the body when squeezed.
                    let pull = squeeze * 44
                    var handle = Path()
                    handle.move(to: CGPoint(x: 244 + pull, y: 212 - squeeze * 8))
                    handle.addLine(to: CGPoint(x: 326, y: 183))
                    handle.addLine(to: CGPoint(x: 326, y: 712))
                    handle.addLine(to: CGPoint(x: 303 + pull * 0.4, y: 710))
                    handle.closeSubpath()
                    g.fill(handle, with: .color(hex(0xEB6133)))
                    // Cable
                    g.fill(rect(629, 1140, 12, 221, 2), with: .color(hex(0x9E9E9E)))
                    for i in 0..<5 { g.fill(rect(600, 1161 + Double(i) * 32, 71, 20, 10), with: .color(hex(0x9E9E9E))) }
                    // Side buttons, pushed in when pressed
                    let buttons: [(Double, Double, UInt32, UInt32)] =
                        [(1056, 161, 0xE9805A, 0xB4603F), (1067, 417, 0xF6F6F4, 0xBDBDBB), (1067, 857, 0xDADAD7, 0xB0B0AE)]
                    for (i, b) in buttons.enumerated() {
                        let inset = i == button ? press * 24 : 0
                        let w = i == 0 ? 34.0 : 48.0
                        let shape = rect(b.0 - inset, b.1, w, i == 0 ? 111 : 112, 18)
                        g.fill(shape, with: .color(hex(b.2)))
                        g.stroke(shape, with: .color(hex(b.3)), lineWidth: 4)
                        if i == button && press > 0 {
                            g.stroke(rect(b.0 - inset - 16, b.1 - 16, w + 32, 144, 28),
                                     with: .color(hex(0xEB6133).opacity(press)), lineWidth: 10)
                        }
                    }
                    // Body and speaker panel
                    let body = rect(323, 73, 744, 1071, 22)
                    g.fill(body, with: .color(hex(0xF2F2F0)))
                    g.stroke(body, with: .color(hex(0xCCCCCA)), lineWidth: 4)
                    g.fill(Path(roundedRect: CGRect(x: 323, y: 73, width: 744, height: 583),
                                cornerRadii: .init(topLeading: 22, bottomLeading: 18, bottomTrailing: 18, topTrailing: 22)),
                           with: .color(hex(0x787878)))
                    // Speaker dots: they darken from the top with the voice, like the reference's level.
                    let level = !speaking ? 0 : isLive ? loudness * 10 : 1.5 + abs(sin(t * 7)) * 4 + abs(sin(t * 17)) * 1.5
                    for row in 0..<10 {
                        let fill: Color = Double(row) < level.rounded(.down) ? hex(0x404040)
                            : Double(row) < level ? hex(0x757572) : hex(0xCDC9BC)
                        for col in 0..<11 {
                            g.fill(dot(389 + Double(col) * 50.4, 139 + Double(row) * 54.4, 18), with: .color(fill))
                        }
                    }
                    // The two LED strips
                    for (top, lit, color) in [(137.0, 215.0, hex(0xEE4230)), (393.0, sweepY, Color.white)] {
                        g.fill(rect(971, top, 48, 215, 24), with: .color(hex(0x5C5C5C)))
                        for i in 0..<4 {
                            let y = top + 32 + Double(i) * 46
                            if abs(y - lit) < 8 { g.fill(dot(995, y, 27), with: .color(color.opacity(0.28))) }
                            g.fill(dot(995, y, 12), with: .color(abs(y - lit) < 8 ? color : hex(0x8A8A8A)))
                        }
                    }
                    // Screws
                    for (x, y) in [(387.0, 721.0), (1002.0, 721.0), (387.0, 1081.0), (1002.0, 1081.0)] {
                        g.stroke(dot(x, y, 25), with: .color(hex(0xCCCCCA)), lineWidth: 4)
                    }
                }
                let holding = gesture.isModeSwitch && press > 0.5
                Label(isLive ? gesture.label
                          : done ? outcome(gesture)
                          : gesture == .show ? "Press" : gesture == .hangUp ? "Press twice"
                          : gesture.isModeSwitch ? (holding ? "Hold… \(min(3, Int(t - 0.4) + 1)) s" : "Hold")
                          : squeeze > 0.5 ? "Listening" : "Squeeze",
                      systemImage: done ? icon(gesture)
                          : !gesture.usesHandle ? "hand.tap.fill"
                          : squeeze > 0.5 ? "waveform" : "arrow.right.and.line.vertical.and.arrow.left")
                    .font(.ui(14, .semibold))
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Capsule().fill(done ? ink.accent.opacity(0.18) : ink.hover))
                    .scaleEffect(done ? 1.06 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.55), value: done)
            }
            .frame(maxWidth: .infinity)
        }
    }

    func outcome(_ gesture: MicGesture) -> String {
        switch gesture {
        case .talk: "Listening"
        case .send: "Sent"
        case .queue: "Queued"
        case .draft: "In draft"
        case .cancel: "Gone"
        case .hangUp: "Muted"
        case .show: Settings.shared.bottomButton == "panel" ? "Panel opens" : Settings.shared.bottomButton == "none" ? "Nothing" : "Claude"
        case .ko2, .claude: "Now restart the mic"
        }
    }
    func icon(_ gesture: MicGesture) -> String {
        switch gesture {
        case .talk: "waveform"
        case .send: "paperplane.fill"
        case .queue: "clock.fill"
        case .draft: "square.and.pencil"
        case .cancel: "xmark.circle.fill"
        case .show: "macwindow"
        case .hangUp: "mic.slash.fill"
        case .ko2, .claude: "arrow.clockwise"
        }
    }
}


/// Settings and lists the panel shows, read from the app when it opens and after each change.
final class PanelModel: ObservableObject {
    enum Page { case main, pick, gestures, settings }
    @Published var page = Page.main
    @Published var pins: [String] = []
    @Published var selected: String?
    /// The conversation Claude shows right now, nil when it has no readable title. Followed while the panel is open.
    @Published var onScreen: String?
    private var follow: Timer?
    @Published var pickable: [String]?
    @Published var revision = 0                    // bumped after a setting changes, to redraw
    @Published var recording = false
    private let recorder = ShortcutRecorder()
    unowned let controller: AppController
    private let settings = Settings.shared

    init(controller: AppController) { self.controller = controller }

    func startFollowing() {
        let read = { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let title = ComposerDelivery.onScreenTitle()
                DispatchQueue.main.async { if self?.onScreen != title { self?.onScreen = title } }
            }
        }
        read()
        follow = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in read() }
    }

    func stopFollowing() { follow?.invalidate(); follow = nil }

    func reload() {
        selected = settings.targetSessionTitle
        var kept = settings.pinnedTitles
        if let selected, !kept.contains(selected) { kept.append(selected) }
        pins = kept
        revision += 1
    }

    func select(_ chat: String?) {
        if let chat, !pins.contains(chat) { pins.append(chat) }
        selected = chat
        settings.pinnedTitles = pins
        settings.targetSessionTitle = chat
        Log.write("target: \(chat == nil ? "conversation on screen" : "pinned conversation")")
        controller.snapshot()
    }

    func unpin(_ chat: String) {
        pins.removeAll { $0 == chat }
        settings.pinnedTitles = pins
        if selected == chat { select(nil) }
    }

    /// Only conversations with a sidebar row can be shown, so only those are offered.
    func loadPickable() {
        pickable = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let titles = ComposerDelivery.reachable(SessionStore.recent(limit: 200).map(\.title))
            DispatchQueue.main.async { self.pickable = titles }
        }
    }

    func binding(_ read: @escaping () -> Bool, _ write: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: read, set: { write($0); self.revision += 1; self.controller.snapshot() })
    }

    func setInput(_ name: String) {
        settings.deviceQuery = name
        Log.write("input device set to \(name)")
        if controller.state != .idle { controller.disarm(reason: "Switching input") }
        controller.arm()
        revision += 1
    }

    func recordShortcut() {
        let s = settings
        let old = (s.hotKeyCode, s.hotKeyModifiers, s.hotKeyLabel)
        recording = true
        HotKey.unregister()
        recorder.record(current: s.hotKeyLabel) { [weak self] result in
            guard let self else { return }
            self.recording = false
            if let (code, mods, label) = result {
                s.hotKeyCode = Int(code); s.hotKeyModifiers = Int(mods); s.hotKeyLabel = label
                if !self.controller.registerHotKey() {
                    (s.hotKeyCode, s.hotKeyModifiers, s.hotKeyLabel) = old
                    self.controller.registerHotKey()
                    self.controller.hud.flash("\(label) is taken", tint: .red, icon: "keyboard", seconds: 3)
                }
            } else {
                self.controller.registerHotKey()
            }
            self.revision += 1
        }
    }
}

struct PanelView: View {
    @Environment(\.colorScheme) var scheme
    @ObservedObject var model: PanelModel
    @ObservedObject var live: LiveMic
    @ObservedObject var island: HUDModel
    @State private var query = ""
    @State private var chosen = MicGesture.send
    @FocusState private var searching: Bool
    var close: () -> Void

    private var squeezingNow: Bool { island.shown && (island.title == "Listening" || island.title == "Starting…") }

    var body: some View {
        let ink = Ink.of(scheme)
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                liveArea(ink)
                // What the bottom row opens appears under everything, from the top, in one place.
                ZStack(alignment: .top) {
                if squeezingNow && model.page != .gestures {
                    // The squeeze rail takes this place until the handle is let go.
                } else if model.page == .gestures {
                    gesturesPage(ink).transition(.opacity.combined(with: .offset(y: -8)))
                } else if model.page != .main || !ComposerDelivery.isTrusted {
                    VStack(alignment: .leading, spacing: 4) {    // its own glass, apart from the live area
                        switch model.page {
                        case .main: mainPage(ink)
                        case .pick: pickPage(ink)
                        case .gestures: EmptyView()
                        case .settings: settingsPage(ink)
                        }
                    }
                    .padding(10)
                    .frosted(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: ink.wash)
                    .id(model.page)
                    .transition(.opacity.combined(with: .offset(y: -8)))
                }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: island.shown)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.page)
        .font(.ui(14)).foregroundStyle(ink.primary)
        .frame(width: IslandStack<EmptyView>.width)
        .padding(12)
    }

    // MARK: live

    /// The same island as the floating one, here with hang up or answer beside it; between messages it says how to
    /// start one.
    @ViewBuilder func liveArea(_ ink: Ink) -> some View {
        // On USB the input is closed between squeezes anyway and a squeeze wakes it: no muted state, no mute button.
        let off = live.state == .idle && !live.usb
        IslandStack(model: island,
                    // With the mic on USB a squeeze unmutes, so say so; over the audio cable only the Mac can.
                    idle: island.shown ? nil : off ? ("Muted", "mic.slash", false) : ("Squeeze to talk", "waveform", true),
                    idleDestination: off ? nil : model.selected ?? model.onScreen ?? "Conversation on screen",
                    onUnpin: { model.select(nil) },
                    showsPin: model.page != .pick,
                    fixed: AnyView(HStack(spacing: 8) {
                        switcher(.pick, "Chats", nil, ink)
                        switcher(.gestures, "Gestures", "hand.point.up.left", ink)
                        switcher(.settings, "Settings", "gearshape", ink)
                    }),
                    railAlways: model.page == .gestures,
                    demoPick: squeezeSet.firstIndex(of: doing),
                    onPick: { chosen = squeezeSet[$0] }) {
            // Mute is plain glass; unmuting, the one thing to find when it's off, is green.
            if !live.usb {
            Button { model.controller.toggleArmed(source: "panel") } label: {
                Label(off ? "Unmute" : "Mute", systemImage: off ? "mic.fill" : "mic.slash.fill")
                    .font(.ui(14, .semibold)).foregroundStyle(off ? .white : ink.primary)
                    .padding(.horizontal, 18).frame(height: 56).fixedSize()
                    .contentTransition(.symbolEffect(.replace))
                    .glassEffect(off ? .regular.tint(Color(red: 0.08, green: 0.50, blue: 0.24).opacity(0.75)).interactive()
                                     : .regular.tint(ink.dense).interactive(), in: Capsule())
                    .background(.ultraThinMaterial, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            }
        }
    }

    /// `icon` nil shows Claude's own icon: these are Claude conversations.
    func switcher(_ page: PanelModel.Page, _ title: String, _ icon: String?, _ ink: Ink) -> some View {
        let on = model.page == page
        return Button {
            go(on ? .main : page)
            if !on && page == .pick { model.loadPickable() }
        } label: {
            Label {
                Text(title)
            } icon: {
                if let icon { Image(systemName: icon) } else { ClaudeMark(size: 20) }
            }
                .font(.ui(14, .semibold)).foregroundStyle(on ? .white : ink.primary)
                .frame(maxWidth: .infinity).frame(height: 56)
                .frosted(Capsule(), tint: on ? Color.accentGlass.opacity(0.75) : ink.dense)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: pages

    func go(_ page: PanelModel.Page) { withAnimation(.snappy) { model.page = page; query = "" } }

    func chevron(_ ink: Ink) -> some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary)
    }

    func back(_ title: String, _ ink: Ink) -> some View {
        PanelRow(action: { go(.main) }) {
            Image(systemName: "chevron.left").fontWeight(.semibold).frame(width: 28)
            Text(title).font(.ui(17, .semibold))
        }
    }

    @ViewBuilder func mainPage(_ ink: Ink) -> some View {
        if !ComposerDelivery.isTrusted {
            PanelRow(action: { ComposerDelivery.requestAccess() }) {
                Image(systemName: "exclamationmark.triangle").frame(width: 28); Text("Allow Accessibility access")
            }
        }
    }

    @ViewBuilder func pickPage(_ ink: Ink) -> some View {
        // Clicking a pin sends there; clicking it again goes back to the conversation on screen.
        if !model.pins.isEmpty { group("Pinned", ink) }
        ForEach(model.pins, id: \.self) { chat in
            PinnedRow(title: chat, selected: model.selected == chat, ink: ink,
                      select: { model.select(model.selected == chat ? nil : chat) }, unpin: { model.unpin(chat) })
        }
        if !model.pins.isEmpty { group("Add", ink) }
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ink.secondary)
            TextField("Search sidebar conversations", text: $query).textFieldStyle(.plain).font(.ui(14))
                .focused($searching)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.hover))
        .onAppear { searching = true }
        ScrollView {
            VStack(spacing: 2) {
                if let all = model.pickable {
                    // Pinned ones are above already, so each conversation (and its pin) is on screen once.
                    let found = all.filter { !model.pins.contains($0) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }
                    ForEach(found, id: \.self) { chat in
                        PanelRow(selected: model.selected == chat, action: { model.select(chat); go(.main) }) {
                            ClaudeIcon(size: 22).frame(width: 28)
                            Text(chat).lineLimit(1)
                            Spacer()
                        }
                    }
                    if found.isEmpty { Text("No conversation matches").foregroundStyle(ink.secondary).frame(height: 44) }
                } else {
                    ProgressView().controlSize(.small).frame(height: 44)
                }
            }
        }
        .frame(height: 276)
    }

    func group(_ title: String, _ ink: Ink) -> some View {
        Text(title).font(.mono(12, .semibold)).foregroundStyle(ink.secondary)
            .padding(.horizontal, 12).padding(.top, 6)
    }

    /// A mode switch, played on the drawing. What to do while talking is shown by the pills under the status.
    func modePill(_ gesture: MicGesture, _ ink: Ink) -> some View {
        let on = chosen == gesture
        return Button { withAnimation(.snappy) { chosen = gesture } } label: {
            Text(gesture.label)
                .font(.ui(14, on ? .semibold : .medium)).foregroundStyle(on ? ink.accent : ink.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(on ? ink.accent.opacity(0.16) : ink.hover))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var bottomButtonLabel: String {
        switch Settings.shared.bottomButton {
        case "claude": "Bottom shows\nClaude"
        case "toggle": "Bottom flips\nto Claude"
        case "none": "Bottom does\nnothing"
        default: "Bottom opens\npanel"
        }
    }

    /// The squeeze rail's gestures, in its order (it lives in the island above).
    private var squeezeSet: [MicGesture] { Settings.shared.shakeToCancel ? [.send, .queue, .draft, .cancel] : [.send, .queue, .draft] }

    /// What the rails highlight: for a moment after the real mic did something, that; otherwise the picked demo.
    private var doing: MicGesture {
        let recent = live.flashAt.map { Date().timeIntervalSince($0) < 2.5 } == true
        guard recent, let last = live.last else { return chosen }
        return last == .talk ? .send : last
    }

    /// Below the squeeze rail: the same rail for what the buttons do with the handle released, then one card that only
    /// holds the drawing and its caption, whatever is picked above.
    @ViewBuilder func gesturesPage(_ ink: Ink) -> some View {
        let claude = chosen == .claude
        let mode: MicGesture = claude ? .claude : .ko2
        let released: [MicGesture] = live.usb ? [.show, mode] : [.show, .hangUp, mode]
        VStack(spacing: 10) {
            ActionRail(items: released.map { gesture in
                switch gesture {
                case .show: RailItem(bottomButtonLabel) { MicButtonGlyph(pressed: 2, line: ink.secondary) }
                case .hangUp: RailItem("Twice to\nmute") { MicButtonGlyph(pressed: 2, line: ink.secondary) }
                default: RailItem(claude ? "Hold top\nfor Claude" : "Hold middle\nfor K.O. II") {
                    MicButtonGlyph(pressed: claude ? 0 : 1, line: ink.secondary)
                }
                }
            }, selected: live.squeezing ? nil : released.firstIndex(of: doing), onPick: { chosen = released[$0] })
            MicDemo(chosen: chosen, ink: ink, live: live, island: island).id(chosen)
                .frame(maxWidth: .infinity, minHeight: 232, maxHeight: 232)
                .padding(10)
                .frosted(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: ink.wash)
        }
        .task(id: chosen) {          // the mode item plays both directions in turn
            guard chosen.isModeSwitch else { return }
            try? await Task.sleep(for: .seconds(5.4))
            if !Task.isCancelled { withAnimation(.snappy) { chosen = chosen == .ko2 ? .claude : .ko2 } }
        }
    }

    func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) { Text(title).frame(maxWidth: .infinity, alignment: .leading) }
            .toggleStyle(.switch).padding(.horizontal, 12).frame(minHeight: 40)
    }

    @ViewBuilder func settingsPage(_ ink: Ink) -> some View {
        let s = Settings.shared
        let _ = model.revision
        HStack {
            Text("Input")
            Spacer()
            Picker("", selection: Binding(
                get: { AudioDevices.inputs().first { $0.name.localizedCaseInsensitiveContains(s.deviceQuery) || $0.uid == s.deviceQuery }?.name ?? "" },
                set: { model.setInput($0) })) {
                    ForEach(AudioDevices.inputs().map(\.name), id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(maxWidth: 190)
        }.padding(.horizontal, 12).frame(minHeight: 40)
        toggle("Close mic between squeezes (USB)", model.binding({ s.usbTrigger }, { s.usbTrigger = $0; model.controller.setUSBTrigger($0) }))
        toggle("Use Claude’s dictation", model.binding({ s.transcriptionEngine == "claude" }, { s.transcriptionEngine = $0 ? "claude" : "apple" }))
        if s.transcriptionEngine == "claude" {
            toggle("Fall back to Apple’s recognizer", model.binding({ s.appleFallback }, { s.appleFallback = $0 }))
        }
        HStack {
            Text("Bottom button")
            Spacer()
            Picker("", selection: Binding(get: { s.bottomButton }, set: {
                s.bottomButton = $0
                Log.write("bottom button: \($0)")
                model.revision += 1
            })) {
                Text("Opens this panel").tag("panel")
                Text("Brings Claude forward").tag("claude")
                Text("Shows or hides Claude").tag("toggle")
                Text("Does nothing").tag("none")
            }.labelsHidden().fixedSize()
        }.padding(.horizontal, 12).frame(minHeight: 40)
        toggle("Shake to cancel", model.binding({ s.shakeToCancel }, { s.shakeToCancel = $0 }))
        toggle("Show activity in menu bar", model.binding({ s.statusBadge }, { s.statusBadge = $0 }))
        toggle("Open at login", model.binding({ SMAppService.mainApp.status == .enabled }, { on in
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { Log.write("launch at login failed: \(error)") }
        }))
        HStack {
            Text("Mute shortcut")
            Spacer()
            Button(model.recording ? "Press keys…" : s.hotKeyLabel) { model.recordShortcut() }
                .font(.mono(13)).controlSize(.large).buttonStyle(.bordered)
        }.padding(.horizontal, 12).frame(minHeight: 40)
        Divider().padding(.horizontal, 12).padding(.vertical, 2)
        PanelRow(action: { NSApp.terminate(nil) }) { Image(systemName: "power").frame(width: 28); Text("Quit FXMic") }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows and hides the panel under the menu bar icon. It stays open while you use Claude and the mic; the icon or
/// Esc closes it.
final class IslandPanelController: NSObject {
    private let controller: AppController
    private let model: PanelModel
    private var panel: NSPanel?
    private var keys: Any?
    private var top = NSPoint.zero

    init(controller: AppController) {
        self.controller = controller
        model = PanelModel(controller: controller)
        super.init()
    }

    func toggle(under button: NSStatusBarButton) {
        if panel != nil { close() } else { open(under: button) }
    }

    private func open(under button: NSStatusBarButton) {
        model.page = .main
        model.reload()
        controller.live.state = controller.state
        controller.live.usb = controller.usbLiveMain
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 444, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screen = button.window?.screen ?? NSScreen.main
        let anchor = button.window?.frame ?? .zero
        let visible = screen?.visibleFrame ?? .zero
        top = NSPoint(x: min(anchor.midX - 222, visible.maxX - 448), y: visible.maxY)
        let host = NSHostingView(rootView: PanelView(model: model, live: controller.live, island: controller.hud.model,
                                                     close: { [weak self] in self?.close() })
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        // As tall as the screen allows and never resized, so content only ever grows downward from the top. The empty
        // part is transparent, which lets clicks through.
        p.setFrame(NSRect(x: top.x, y: visible.minY, width: 444, height: top.y - visible.minY), display: false)
        controller.hud.setEmbedded(true)
        p.makeKeyAndOrderFront(nil)
        model.startFollowing()
        Log.write("panel: opened")
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, self?.model.recording == false else { return e }
            self?.close()
            return nil
        }
    }

    private func close() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        panel?.orderOut(nil)
        panel = nil
        controller.hud.setEmbedded(false)
        model.stopFollowing()
        Log.write("panel: closed")
    }
}

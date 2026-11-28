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
    /// Its hover in this color instead of the plain one (Quit).
    var tint: Color? = nil
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var over = false
    var body: some View {
        let ink = Ink.of(scheme)
        Button(action: action) {
            HStack(spacing: 12) { content }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: Metric.row, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Metric.inner, style: .continuous)
                    .fill(selected ? ink.accent.opacity(0.14) : over ? (tint?.opacity(0.16) ?? ink.hover) : .clear))
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
                .padding(.leading, 12).frame(minHeight: Metric.row).contentShape(Rectangle())
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
        .background(RoundedRectangle(cornerRadius: Metric.inner, style: .continuous)
            .fill(selected ? ink.accent.opacity(0.14) : overRow ? ink.hover : .clear))
        .onHover { overRow = $0 }
        .animation(.easeOut(duration: 0.12), value: overPin)
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
    /// The gestures page plays every gesture in turn until one is picked.
    @State private var touring = true
    @FocusState private var searching: Bool
    /// The panel's look: one sheet of Liquid Glass (the default), or each piece as its own glass.
    @AppStorage("panelSeparatePieces") private var separate = false
    var close: () -> Void

    /// Whether anything goes below the page buttons; an empty section would still add its gap to the bottom margin.
    private var showsPage: Bool {
        if model.page == .gestures { return true }
        if squeezingNow { return false }
        return model.page != .main || !ComposerDelivery.isTrusted
    }

    private var squeezingNow: Bool { island.shown && (island.title == "Listening" || island.title == "Starting…") }

    var body: some View {
        let ink = Ink.of(scheme)
        VStack(spacing: Metric.gap) {
            VStack(spacing: Metric.gap) {
                liveArea(ink)
                // What the bottom row opens appears under everything, from the top, in one place. While the handle is
                // squeezed the squeeze rail takes this place on the other pages.
                if showsPage {
                    ZStack(alignment: .top) {
                        if model.page == .gestures {
                            gesturesPage(ink).transition(.opacity.combined(with: .offset(y: -8)))
                        } else {
                            VStack(alignment: .leading, spacing: model.page == .settings ? Metric.gap : 4) {
                                switch model.page {
                                case .main: mainPage(ink)
                                case .pick: pickPage(ink)
                                case .gestures: EmptyView()
                                case .settings: settingsPage(ink)
                                }
                            }
                            // Straight on the sheet; as separate pieces the page needs its own card.
                            .modifier(PageCard(on: separate, tint: ink.wash))
                            .id(model.page)
                            .transition(.opacity.combined(with: .offset(y: -8)))
                        }
                    }
                }
            }
            // One sheet of the system's Liquid Glass, untinted; the same margin all round, corners concentric with the
            // cards inside it.
            .environment(\.onSheet, !separate)
            .padding(separate ? 0 : Metric.sheetPad)
            .background { if !separate { SystemGlass(radius: Metric.card + Metric.sheetPad) } }
        }
        .animation(.easeInOut(duration: 0.2), value: island.shown)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.page)
        .font(.ui(14)).foregroundStyle(ink.primary)
        .frame(width: IslandStack<EmptyView>.width + (separate ? 0 : 2 * Metric.sheetPad))
        .padding(.top, 8).padding(.bottom, Metric.sheetMargin).padding(.horizontal, Metric.sheetMargin)
    }

    // MARK: live

    /// The same island as the floating one, here with hang up or answer beside it; between messages it says how to
    /// start one.
    @ViewBuilder func liveArea(_ ink: Ink) -> some View {
        // On USB the input is closed between squeezes anyway and a squeeze wakes it: no muted state, no mute button.
        let off = live.state == .idle && !live.usb
        IslandStack(model: island,
                    // Muted, the main pill is the invitation and a click on it opens the mic; the round button beside
                    // it only mutes and unmutes. With the mic on USB a squeeze opens it, so there is no muted state.
                    idle: island.shown ? nil : off ? ("Open the mic", "mic.fill", false) : ("Squeeze to talk", "waveform", true),
                    idleTint: off ? Color.unmuteGlass : nil,
                    onIdleTap: off ? { model.controller.toggleArmed(source: "panel") } : nil,
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
                    onPick: { pick(squeezeSet[$0]) }) {
            // Icon only, in tinted Liquid Glass: red mutes, green unmutes. Glass drawn directly with a translucent tint
            // stays glass when the panel has focus (.glassProminent turns into a flat fill there).
            if !live.usb {
            Button { model.controller.toggleArmed(source: "panel") } label: {
                Image(systemName: off ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: Metric.bar, height: Metric.bar)
                    .contentTransition(.symbolEffect(.replace))
                    .modifier(MuteGlass(tint: (off ? Color.unmuteGlass : ink.danger).opacity(0.55)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(off ? "Unmute" : "Mute")
            .accessibilityLabel(off ? "Unmute" : "Mute")
            .animation(.snappy, value: off)
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
                .frame(maxWidth: .infinity).frame(height: Metric.bar)
                .frosted(Capsule(), tint: on ? Color.accentGlass.opacity(0.75) : ink.dense)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: pages

    func go(_ page: PanelModel.Page) {
        withAnimation(.snappy) { model.page = page; query = "" }
        if page == .gestures { touring = true }
    }

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
        .padding(.horizontal, 12).frame(height: Metric.row)
        .background(RoundedRectangle(cornerRadius: Metric.inner, style: .continuous).fill(ink.hover))
        .onAppear { searching = true }
        // Pinned ones are above already, so each conversation (and its pin) is on screen once.
        let found = (model.pickable ?? []).filter {
            !model.pins.contains($0) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query))
        }
        ScrollView {
            VStack(spacing: 2) {
                if model.pickable != nil {
                    ForEach(found, id: \.self) { chat in
                        PanelRow(selected: model.selected == chat, action: { model.select(chat); go(.main) }) {
                            ClaudeIcon(size: 22).frame(width: 28)
                            Text(chat).lineLimit(1)
                            Spacer()
                        }
                    }
                    if found.isEmpty { Text("No conversation matches").foregroundStyle(ink.secondary).frame(height: Metric.row) }
                } else {
                    ProgressView().controlSize(.small).frame(height: Metric.row)
                }
            }
        }
        // Only as tall as its rows (up to six), so the bottom margin matches the others.
        .frame(height: CGFloat(min(6, max(1, found.count))) * (Metric.row + 2) - 2)
    }

    func group(_ title: String, _ ink: Ink) -> some View {
        Text(title).font(.mono(12, .semibold)).foregroundStyle(ink.secondary)
            .padding(.horizontal, 12).padding(.top, 6)
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

    /// Picking a gesture stops the tour on it.
    func pick(_ gesture: MicGesture) {
        touring = false
        withAnimation(.snappy) { chosen = gesture }
    }

    /// Each mode switch has its own item: the top and middle holds are different actions.
    private var releasedSet: [MicGesture] { live.usb ? [.show, .claude, .ko2] : [.show, .hangUp, .claude, .ko2] }

    /// Below the squeeze rail: the same rail for what the buttons do with the handle released, then one card that only
    /// holds the tutorial, whatever is picked above. Until something is picked it tours every gesture, one loop each.
    @ViewBuilder func gesturesPage(_ ink: Ink) -> some View {
        let released = releasedSet
        let tour = squeezeSet + released
        VStack(spacing: Metric.gap) {
            ActionRail(items: released.map { gesture in
                switch gesture {
                case .show: RailItem(bottomButtonLabel) { MicButtonGlyph(pressed: 2, line: ink.secondary) }
                case .hangUp: RailItem("Twice to\nmute") { MicButtonGlyph(pressed: 2, line: ink.secondary) }
                case .ko2: RailItem("Hold middle\nfor K.O. II") { MicButtonGlyph(pressed: 1, line: ink.secondary) }
                default: RailItem("Hold top\nfor Claude") { MicButtonGlyph(pressed: 0, line: ink.secondary) }
                }
            }, selected: live.squeezing ? nil : released.firstIndex(of: doing), onPick: { pick(released[$0]) })
            MicDemo(chosen: chosen, ink: ink, live: live, island: island).id(chosen)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22).padding(.vertical, 20)
                .frosted(RoundedRectangle(cornerRadius: Metric.card, style: .continuous), tint: ink.wash)
                .transition(.opacity)
        }
        .task(id: chosen) {
            guard touring else { return }
            try? await Task.sleep(for: .seconds(chosen.demoSeconds))
            guard touring, !Task.isCancelled, let at = tour.firstIndex(of: chosen) else { return }
            withAnimation(.easeInOut(duration: 0.25)) { chosen = tour[(at + 1) % tour.count] }
        }
    }

    func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) { Text(title).frame(maxWidth: .infinity, alignment: .leading) }
            .toggleStyle(.switch).padding(.horizontal, 12).frame(minHeight: Metric.row)
    }

    /// One group of settings in its own rounded container; the rows say what they are, so it carries no title.
    func settingsGroup<Rows: View>(_ ink: Ink, @ViewBuilder _ rows: () -> Rows) -> some View {
        VStack(spacing: 0) { rows() }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: separate ? Metric.inner : Metric.card, style: .continuous).fill(ink.primary.opacity(0.07)))
    }

    /// Grouped by what each setting is about: the mic and how it is opened, how words are heard, what the mic's
    /// own controls do, and the app itself. Quit stands alone, in red.
    @ViewBuilder func settingsPage(_ ink: Ink) -> some View {
        let s = Settings.shared
        let _ = model.revision
        settingsGroup(ink) {
            HStack {
                Text("Input")
                Spacer()
                Picker("", selection: Binding(
                    get: { AudioDevices.inputs().first { $0.name.localizedCaseInsensitiveContains(s.deviceQuery) || $0.uid == s.deviceQuery }?.name ?? "" },
                    set: { model.setInput($0) })) {
                        ForEach(AudioDevices.inputs().map(\.name), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 190)
            }.padding(.horizontal, 12).frame(minHeight: Metric.row)
            toggle("Close mic between squeezes (USB)", model.binding({ s.usbTrigger }, { s.usbTrigger = $0; model.controller.setUSBTrigger($0) }))
            HStack {
                Text("Mute shortcut")
                Spacer()
                Button(model.recording ? "Press keys…" : s.hotKeyLabel) { model.recordShortcut() }
                    .font(.mono(13)).buttonStyle(.bordered)
            }.padding(.horizontal, 12).frame(minHeight: Metric.row)
        }
        settingsGroup(ink) {
            toggle("Use Claude’s dictation", model.binding({ s.transcriptionEngine == "claude" }, { s.transcriptionEngine = $0 ? "claude" : "apple" }))
            if s.transcriptionEngine == "claude" {
                toggle("Fall back to Apple’s recognizer", model.binding({ s.appleFallback }, { s.appleFallback = $0 }))
            }
        }
        settingsGroup(ink) {
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
            }.padding(.horizontal, 12).frame(minHeight: Metric.row)
            toggle("Shake to cancel", model.binding({ s.shakeToCancel }, { s.shakeToCancel = $0 }))
        }
        settingsGroup(ink) {
            HStack {
                Text("Panel")
                Spacer()
                Picker("", selection: $separate) {
                    Text("One sheet").tag(false)
                    Text("Separate pieces").tag(true)
                }.labelsHidden().fixedSize()
            }.padding(.horizontal, 12).frame(minHeight: Metric.row)
            toggle("Show activity in menu bar", model.binding({ s.statusBadge }, { s.statusBadge = $0 }))
            toggle("Open at login", model.binding({ SMAppService.mainApp.status == .enabled }, { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { Log.write("launch at login failed: \(error)") }
            }))
        }
        PanelRow(tint: ink.danger, action: { NSApp.terminate(nil) }) {
            // Lined up with the rows above: words on the left, the control on the far right.
            Text("Quit \(AppName.display)").fontWeight(.semibold)
            Spacer()
            Image(systemName: "power").fontWeight(.semibold)
        }
        .foregroundStyle(ink.danger)
        .background(RoundedRectangle(cornerRadius: separate ? Metric.inner : Metric.card, style: .continuous).fill(ink.danger.opacity(0.08)))
    }
}

/// Apple's Liquid Glass view itself, as the panel's sheet: it samples the screen behind the window and lights its own
/// edges, which is what makes it look like the system's panels.
private struct SystemGlass: NSViewRepresentable {
    let radius: CGFloat
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = radius
        return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) { view.cornerRadius = radius }
}

/// The card a page sits in when the panel is separate pieces; nothing on the sheet.
private struct PageCard: ViewModifier {
    let on: Bool
    let tint: Color
    func body(content: Content) -> some View {
        if on {
            content.padding(Metric.pad).frosted(RoundedRectangle(cornerRadius: Metric.card, style: .continuous), tint: tint)
        } else {
            content
        }
    }
}

/// The mute button's own clear glass; a plain fill on the sheet.
private struct MuteGlass: ViewModifier {
    @Environment(\.onSheet) private var onSheet
    let tint: Color
    func body(content: Content) -> some View {
        if onSheet { content.background(tint, in: Circle()) } else { content.glassEffect(.clear.tint(tint).interactive(), in: Circle()) }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows and hides the panel under the menu bar icon. It stays open while you use Claude and the mic; the icon or
/// Esc closes it.
final class IslandPanelController: NSObject {
    private static let windowWidth: CGFloat = 420 + 2 * (Metric.sheetPad + Metric.sheetMargin)
    private let controller: AppController
    private let model: PanelModel
    private var panel: NSPanel?
    private var keys: Any?
    private var top = NSPoint.zero
    /// Where the panel was dragged to, kept while FXMic runs; it opens there next time.
    private var dragged: NSPoint?
    private var anchored = NSPoint.zero

    init(controller: AppController) {
        self.controller = controller
        model = PanelModel(controller: controller)
        super.init()
    }

    func toggle(under button: NSStatusBarButton) {
        if panel != nil { close() } else { open(under: button) }
    }

    /// Debug: open (if needed) on a named page.
    func show(page: String, under button: NSStatusBarButton) {
        if panel == nil { open(under: button) }
        let pages: [String: PanelModel.Page] = ["main": .main, "pick": .pick, "gestures": .gestures, "settings": .settings]
        withAnimation(.snappy) { model.page = pages[page] ?? .main }
        if model.page == .pick { model.loadPickable() }
    }

    private func open(under button: NSStatusBarButton) {
        model.page = .main
        model.reload()
        controller.live.state = controller.state
        controller.live.usb = controller.usbLiveMain
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Drag it by any part that isn't a control, anywhere on screen, like the prototype.
        p.isMovableByWindowBackground = true
        let screen = button.window?.screen ?? NSScreen.main
        let anchor = button.window?.frame ?? .zero
        let visible = screen?.visibleFrame ?? .zero
        top = NSPoint(x: min(anchor.midX - Self.windowWidth / 2, visible.maxX - Self.windowWidth), y: visible.maxY)
        let host = NSHostingView(rootView: PanelView(model: model, live: controller.live, island: controller.hud.model,
                                                     close: { [weak self] in self?.close() })
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        // As tall as the screen allows and never resized, so content only ever grows downward from the top. The empty
        // part is transparent, which lets clicks through.
        let home = NSRect(x: top.x, y: visible.minY, width: Self.windowWidth, height: top.y - visible.minY)
        anchored = home.origin
        var placed = home
        if let dragged, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: dragged, size: home.size).insetBy(dx: 100, dy: 0)) }) {
            placed.origin = dragged
        }
        p.setFrame(placed, display: false)
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
        if let origin = panel?.frame.origin { dragged = origin == anchored ? nil : origin }
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        panel?.orderOut(nil)
        panel = nil
        controller.hud.setEmbedded(false)
        model.stopFollowing()
        Log.write("panel: closed")
    }
}

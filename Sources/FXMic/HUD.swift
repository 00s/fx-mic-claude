import AppKit
import QuartzCore
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    /// The Claude conversation the message goes to, shown under the meter; empty hides the line.
    @Published var footer = ""
    @Published var level: Float = -80
    @Published var tint: Color = .orange
    @Published var icon = "mic.fill"
    @Published var showMeter = true
    /// What letting go will do with this squeeze: "Queue", "Draft", or nil for send. Only the mode pills show it.
    @Published var intent: String? = nil
    /// Claude's dictation is starting: a spinner in place of the icon, and no meter (nothing is being heard yet).
    @Published var loading = false
    /// On screen: the island slides down into place when true, up and out when false.
    @Published var shown = false
}

/// The island, one component for both places it appears: floating at the top of the screen while you squeeze, and as
/// the top of the panel. Two pieces at most: a status capsule (with whatever action the place offers beside it) and,
/// while there is something going on, one card holding the ways the release can go, the conversation and the words.
struct IslandStack<Action: View>: View {
    @Environment(\.colorScheme) var scheme
    @ObservedObject var model: HUDModel
    /// Set when the island itself has nothing to say (the panel between messages): shown instead of its state.
    var idle: (title: String, icon: String, live: Bool)? = nil
    /// Off where the conversation is already named right below (the panel's "Send to" list).
    var showsDestination = true
    /// Off where the same actions are already on screen (the panel's gestures page).
    var showsModes = true
    /// Between messages: where the next one will go, so the card is there with it. Only the panel sets this.
    var idleDestination: String? = nil
    /// Back from a pinned conversation to the one on screen. Only the panel can offer it.
    var onUnpin: (() -> Void)? = nil
    @ViewBuilder var action: Action
    @Namespace private var highlight

    static var width: CGFloat { 420 }

    /// The modes show for the whole squeeze, dimmed until Claude listens, so the card keeps one shape.
    private var squeezing: Bool { idle == nil && (model.title == "Listening" || model.title == "Starting…") }
    private var destination: String { idle == nil ? model.footer : idleDestination ?? "" }
    private var hasDestination: Bool { showsDestination && !destination.isEmpty }
    /// Queue or draft picked for the squeeze in progress: the status says so, with its own color and symbol.
    private var picked: String? { idle == nil && model.title == "Listening" ? model.intent : nil }
    private var statusTitle: String { idle?.title ?? picked.map { "Listening · \($0)" } ?? model.title }
    private var statusIcon: String { picked == "Queue" ? "clock" : picked == "Draft" ? "square.and.pencil" : model.icon }
    private var statusColor: Color { picked == "Queue" ? .orange : picked == "Draft" ? .blue : model.tint }

    var body: some View {
        let ink = Ink.of(scheme)
        // Every piece is its own glass over the screen, in one container: no glass on glass, and they morph together.
        GlassEffectContainer(spacing: 6) {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                status(ink)
                action
            }
            // The words are their own section; what you can do with them sits below it.
            if hasDestination || (idle == nil && !model.body.isEmpty) {
                transcript(ink).transition(.opacity)
            }
            if squeezing && showsModes {
                modes(ink).transition(.opacity)
            }
        }
        }
        .font(.ui(14))
        .foregroundStyle(ink.primary)
        .frame(width: Self.width)
        // One quiet curve for everything that appears or leaves; nothing springs or morphs.
        .animation(.easeInOut(duration: 0.2), value: squeezing)
        .animation(.easeInOut(duration: 0.2), value: model.body.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: model.footer)
        .animation(.easeInOut(duration: 0.2), value: model.intent)
    }

    /// 0 to 1 while the mic is being heard, nil otherwise.
    private var glow: Double? {
        guard idle == nil, model.showMeter, !model.loading, model.title == "Listening" else { return nil }
        return Double(max(0, min(1, (model.level + 60) / 54)))
    }

    private func status(_ ink: Ink) -> some View {
        let active = idle == nil
        let tint: Color = active ? readable(statusColor) : idle!.live ? ink.live : ink.secondary
        return HStack(spacing: 12) {
            Group {
                if active && model.loading {
                    ProgressView().controlSize(.small)
                } else if idle?.live == true {
                    MicButtonGlyph(pressed: MicButtonGlyph.squeeze, line: ink.secondary)
                } else {
                    Image(systemName: idle?.icon ?? statusIcon).font(.system(size: 20, weight: .medium)).foregroundStyle(tint)
                }
            }
            .frame(width: 34, height: 34)
            Text(statusTitle)
                .font(.ui(18, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.identity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(height: 56).frame(maxWidth: .infinity)
        // While it hears you, color pools inside the glass and flows: it reaches further the louder you are and keeps
        // drifting, so it reads as liquid rather than a meter. (A glass tint itself snaps instead of animating.)
        .background {
            if let level = glow {
                LiquidLevel(color: tint, level: level)
                    .clipShape(Capsule())
                    .transition(.opacity)
            }
        }
        .frosted(Capsule(), tint: ink.dense)
        .scaleEffect(1 + 0.035 * (glow ?? 0))
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: glow)
    }

    private var wordSize: CGFloat {
        switch model.body.count {
        case ..<28: 22
        case ..<70: 19
        case ..<150: 17
        case ..<280: 15
        default: 14
        }
    }

    private func transcript(_ ink: Ink) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasDestination {
                HStack(spacing: 6) {
                    ClaudeIcon(size: 16)
                    Text("Send to")
                    Text(destination).foregroundStyle(ink.primary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if Settings.shared.targetSessionTitle != nil {
                        // One control says both things: it's pinned (the pin) and a click unpins (on hover).
                        if let onUnpin {
                            UnpinButton(ink: ink, action: onUnpin)
                        } else {
                            Image(systemName: "pin.fill").foregroundStyle(ink.accent)
                        }
                    }
                }
                .font(.ui(14, .medium)).foregroundStyle(ink.secondary)
            }
            if idle == nil && !model.body.isEmpty {
                // A few words are set large; the type steps down as there is more to fit.
                Text(model.body).font(.ui(wordSize, .regular)).lineSpacing(wordSize * 0.28)
                    .lineLimit(8).truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.identity)          // new words appear in place, no crossfade
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frosted(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: ink.dense)
    }

    /// What this squeeze can become, drawn where to do it: let go to send, top button to queue, middle to draft,
    /// shake to cancel. Always the same four in the same places; only the highlight slides.
    private func modes(_ ink: Ink) -> some View {
        let chosen = model.intent == "Queue" ? 1 : model.intent == "Draft" ? 2 : 0
        // Each keeps its words: what to do, and what it gets you. Only the highlight moves. Once queue or draft is
        // chosen, letting go no longer sends, so that one fades.
        let count = Settings.shared.shakeToCancel ? 4 : 3
        return HStack(spacing: 0) {
            mode("Release\nto send", chosen == 0, ink) {
                MovingGlyph(kind: .release, line: ink.secondary)
            }
            .opacity(chosen == 0 ? 1 : 0.4)
            mode("Top to\nqueue", chosen == 1, ink) {
                MicButtonGlyph(pressed: 0, line: ink.secondary)
            }
            mode("Middle\nto draft", chosen == 2, ink) {
                MicButtonGlyph(pressed: 1, line: ink.secondary)
            }
            if Settings.shared.shakeToCancel {
                mode("Shake to\ncancel", false, ink) { MovingGlyph(kind: .shake, line: ink.secondary) }
            }
        }
        .background {
            // The selection is one clear drop with a light edge under the chosen action. It travels, stretching as it
            // sets off and settling with a little give. Drawn, not a glass layer: glass draws over the content here.
            GeometryReader { geo in
                let width = geo.size.width / CGFloat(count)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [ink.primary.opacity(0.20), ink.primary.opacity(0.09)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.08), ink.primary.opacity(0.22)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
                    .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: chosen) { drop, scale in
                        drop.scaleEffect(x: scale.width, y: scale.height)
                    } keyframes: { _ in
                        SpringKeyframe(CGSize(width: 1.22, height: 0.92), duration: 0.17)
                        SpringKeyframe(CGSize(width: 0.95, height: 1.03), duration: 0.18)
                        SpringKeyframe(CGSize(width: 1, height: 1), duration: 0.24)
                    }
                    .frame(width: width, height: geo.size.height)
                    .offset(x: width * CGFloat(chosen))
            }
        }
        .padding(6)
        // The track is frost.
        .background(ink.dense, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(ink.primary.opacity(0.10), lineWidth: 1))
        .opacity(model.title == "Starting…" ? 0.45 : 1)
        .animation(.spring(response: 0.42, dampingFraction: 0.68), value: chosen)
    }

    private func mode(_ label: String, _ on: Bool, _ ink: Ink, @ViewBuilder glyph: () -> some View) -> some View {
        VStack(spacing: 5) {
            glyph().frame(width: 34, height: 34)
            Text(label)
                .font(.ui(14, on ? .semibold : .medium)).foregroundStyle(ink.primary)
                .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .scaleEffect(on ? 1.05 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The state colors, dark enough to read on light glass.
    private func readable(_ color: Color) -> Color {
        guard scheme == .light else { return color }
        return color == .yellow ? Ink.of(.light).live : color.mix(with: .black, by: 0.3)
    }
}

extension View {
    /// The island's one material: Liquid Glass over a frost, so what's behind stays soft and text stays readable.
    func frosted(_ shape: some Shape, tint: Color) -> some View {
        glassEffect(.regular.tint(tint).interactive(), in: shape).background(.ultraThinMaterial, in: shape)
    }
}

/// The voice as liquid color: two soft pools that drift across the pill and swell with the level.
struct LiquidLevel: View {
    @Environment(\.accessibilityReduceMotion) private var still
    let color: Color
    var level: Double

    var body: some View {
        TimelineView(.animation(paused: still)) { timeline in
            let t = still ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let drift = sin(t * (i == 0 ? 1.3 : 0.9) + Double(i) * 2.4)
                        Ellipse()
                            .fill(color.opacity(i == 0 ? 0.75 : 0.5))
                            .frame(width: w * (0.28 + 0.55 * level), height: h * (0.7 + 0.9 * level))
                            .position(x: w * (i == 0 ? 0.26 : 0.68) + CGFloat(drift) * w * 0.14,
                                      y: h * 0.5 + CGFloat(cos(t * 1.7 + Double(i))) * h * 0.18)
                    }
                }
                .blur(radius: 18)
                .opacity(0.25 + 0.65 * level)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The transparent canvas the floating island appears in, top-centered. It eases down a little as it fades in, and
/// back as it fades out.
struct HUDCanvas: View {
    @ObservedObject var model: HUDModel
    var body: some View {
        IslandStack(model: model) { EmptyView() }
            .offset(y: model.shown ? 0 : -12)
            .opacity(model.shown ? 1 : 0)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The mic in outline, for the button hints, in the device's own proportions: speaker panel with its holes, the handle
/// on the left, and down the right side the three buttons at their real spacing. One quiet line color; only the part
/// meant is filled, in its own color on the device: the orange, white or grey button, which also sticks out, or the
/// orange handle for the squeeze. (Colors are the FX mic's; the positions hold for either model.)
struct MicButtonGlyph: View {
    /// 0 top, 1 middle, 2 bottom button; `squeeze` for the handle.
    let pressed: Int
    let line: Color
    static let squeeze = 3
    static let shake = 4
    static let none = -1
    /// Point size of the square it is drawn in.
    var side: CGFloat = 34
    /// For the squeeze: how far the handle is pulled in, 0 (let go) to 1 (squeezed).
    var pull: Double = 0
    /// The menu bar's version: the lower half filled white and the speaker holes bigger, so it reads as its own mark
    /// at that size. Inside the app the glyph stays an outline.
    var solid = false
    static let size = CGSize(width: 34, height: 34)

    var body: some View {
        Canvas { g, size in
            // Coordinates from the reference drawing: x 150...1300, y 73...1144.
            let k = min(size.width / 1150, (size.height - 2) / 1071)
            g.translateBy(x: (size.width - 1150 * k) / 2 - 150 * k, y: (size.height - 1071 * k) / 2 - 73 * k)
            g.scaleBy(x: k, y: k)
            let width = 1.1 / k                                       // a 1.1 pt line at any size
            func stroke(_ path: Path, _ color: Color) {
                g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            func hex(_ h: UInt32) -> Color {
                Color(.sRGB, red: Double(h >> 16 & 255) / 255, green: Double(h >> 8 & 255) / 255, blue: Double(h & 255) / 255, opacity: 1)
            }
            let squeezing = pressed == Self.squeeze
            var handle = Path()
            handle.move(to: CGPoint(x: 323, y: 183))
            // Wider when it's the one meant, swinging in toward the body as it is squeezed.
            handle.addLine(to: CGPoint(x: squeezing ? 150 + 140 * pull : 244, y: squeezing ? 235 - 20 * pull : 212))
            handle.addLine(to: CGPoint(x: squeezing ? 230 + 80 * pull : 303, y: 710))
            handle.addLine(to: CGPoint(x: 323, y: 712))
            if squeezing {
                g.fill(handle, with: .color(hex(0xEB6133)))
                stroke(handle, hex(0xEB6133))
            } else {
                stroke(handle, line)
            }
            if solid {
                g.fill(Path(roundedRect: CGRect(x: 323, y: 656, width: 744, height: 488),
                            cornerRadii: .init(topLeading: 0, bottomLeading: 90, bottomTrailing: 90, topTrailing: 0)),
                       with: .color(.white))
                for row in 0..<3 {                                    // the speaker grille
                    for col in 0..<3 {
                        g.fill(Path(ellipseIn: CGRect(x: 450 + Double(col) * 190, y: 170 + Double(row) * 160, width: 112, height: 112)),
                               with: .color(line))
                    }
                }
            }
            stroke(Path(roundedRect: CGRect(x: 323, y: 73, width: 744, height: 1071), cornerRadius: 90, style: .continuous), line)
            var panel = Path()
            panel.move(to: CGPoint(x: 323, y: 656))
            panel.addLine(to: CGPoint(x: 1067, y: 656))
            stroke(panel, line)
            for row in 0..<(solid || size.height < 24 ? 0 : 3) {               // a hint of the speaker holes, when there's room
                for col in 0..<4 {
                    g.fill(Path(ellipseIn: CGRect(x: 440 + Double(col) * 150, y: 180 + Double(row) * 150, width: 66, height: 66)),
                           with: .color(line.opacity(0.7)))
                }
            }
            if pressed == Self.shake {                                // motion marks either side
                for (x, bulge) in [(168.0, -60.0), (1232.0, 60.0)] {
                    var mark = Path()
                    mark.move(to: CGPoint(x: x, y: 380))
                    mark.addQuadCurve(to: CGPoint(x: x, y: 840), control: CGPoint(x: x + bulge * 1.6, y: 610))
                    stroke(mark, hex(0xEB6133))
                }
            }
            for (i, y) in [236.0, 500.0, 913.0].enumerated() {
                let on = i == pressed
                let height = on ? 250.0 : 170.0
                let button = Path(roundedRect: CGRect(x: 1067, y: y - height / 2, width: on ? 223 : 80, height: height),
                                  cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 60, topTrailing: 60))
                if on {
                    let color = [hex(0xEE6A3A), Color.white, hex(0xA9A9A4)][i]
                    g.fill(button, with: .color(color))
                    // White and grey keep the line around them, so they stand out on light glass too.
                    stroke(button, i == 0 ? color : line)
                } else {
                    stroke(button, line)
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel(pressed < 0 ? "Mic" : ["Top button", "Middle button", "Bottom button", "Squeeze handle", "Shake"][min(pressed, 4)])
    }
}

/// The two gestures that are movements, played in a loop: the handle held in and then let go, and the mic being
/// shaken. Still, in their telling pose, when Reduce Motion is on.
struct MovingGlyph: View {
    enum Kind { case release, shake }
    @Environment(\.accessibilityReduceMotion) private var still
    let kind: Kind
    let line: Color

    var body: some View {
        TimelineView(.animation(paused: still)) { timeline in
            // Letting go repeats briskly; a shake only now and then, so it doesn't nag.
            let period = kind == .release ? 1.8 : 4.5
            let t = still ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            switch kind {
            case .release:
                // Squeezed for a second, then it springs out and rests: "let go".
                let pull = still ? 0 : t < 0.2 ? t / 0.2 : t < 1.1 ? 1 : max(0, 1 - (t - 1.1) / 0.12)
                MicButtonGlyph(pressed: MicButtonGlyph.squeeze, line: line, pull: pull)
            case .shake:
                let strength = t < 0.6 ? sin(.pi * t / 0.6) : 0
                MicButtonGlyph(pressed: MicButtonGlyph.shake, line: line)
                    .rotationEffect(.degrees(sin(t * 34) * 16 * strength))
                    .offset(x: sin(t * 34) * 2.5 * strength)
            }
        }
    }
}

/// A filled pin that becomes an unpin under the pointer, in its own round hover area.
struct UnpinButton: View {
    let ink: Ink
    let action: () -> Void
    @State private var over = false
    var body: some View {
        Button(action: action) {
            Image(systemName: over ? "pin.slash.fill" : "pin.fill")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(over ? ink.danger : ink.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(over ? ink.danger.opacity(0.18) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .animation(.easeOut(duration: 0.12), value: over)
        .help("Unpin: send to the conversation on screen")
        .accessibilityLabel("Unpin")
    }
}

/// The installed Claude app's own icon, marking a name as a Claude conversation. Read from the app on this Mac.
struct ClaudeIcon: View {
    var size: CGFloat
    private static let image: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeApp.bundleID)
        .map { NSWorkspace.shared.icon(forFile: $0.path) }
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(systemName: "bubble.left.fill")
        }
    }
}

extension Color {
    /// The accent behind a selected piece of glass: white text reads on it in light and dark.
    static let accentGlass = Color(.sRGB, red: 0.145, green: 0.388, blue: 0.922, opacity: 1)
}

/// The app's two typefaces, bundled (fonts/): Inter Tight for what you read and click, JetBrains Mono for the
/// device-readout captions and states. SF Symbols keep the system font.
extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Inter Tight", fixedSize: size).weight(weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("JetBrains Mono", fixedSize: size).weight(weight) }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Floating, click-through status panel at the top center of the screen. Never takes focus.
final class HUDController {
    let model = HUDModel()
    private let panel: HUDPanel
    private var hideWork: DispatchWorkItem?
    private var lastPartial = ""
    private var target = ""
    private var suppressPartials = false
    /// The panel is open and shows the island's state itself: the floating island stays away.
    private var embedded = false

    func setEmbedded(_ on: Bool) {
        embedded = on
        if on { panel.orderOut(nil) } else { model.shown = false }
    }

    init() {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 70), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false             // the island draws its own shadow; the window is a transparent canvas
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDCanvas(model: model))
    }

    /// The canvas: wide enough for the wide island and its shadow, tall enough for a long transcript, its top at the
    /// top of the visible screen. Transparent and click-through, so its empty part is invisible.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let width = IslandStack<EmptyView>.width + 60
        let height = (frame.height * 0.6).rounded()
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: false)
    }

    func show() {
        if embedded { hideWork?.cancel(); model.shown = true; return }
        guard Settings.shared.hudEnabled else { return }
        hideWork?.cancel()
        if panel.isVisible, model.shown { return }       // already on screen: SwiftUI animates the change in place
        if !panel.isVisible {
            place()
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.shown = false }
            panel.orderFrontRegardless()
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { self.model.shown = true }
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.embedded { withAnimation(.easeInOut(duration: 0.2)) { self.model.shown = false }; return }
            guard self.panel.isVisible else { return }
            withAnimation(.easeIn(duration: 0.16)) { self.model.shown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !self.model.shown { self.panel.orderOut(nil) }     // unless it was shown again meanwhile
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Handle released, transcript being finalized and typed: same toast, new label.
    /// `target`: the conversation the message will go to, when already known; nil leaves the line off until it is.
    func listening(target: String?) {
        suppressPartials = false
        model.intent = nil
        model.loading = false
        model.title = "Listening"
        model.body = ""
        model.footer = target ?? ""
        model.tint = .yellow
        model.icon = "mic.fill"
        model.showMeter = true
        model.level = -60
        show()
    }

    /// FXMic could not open the input for this squeeze, so there is no level to show: the meter goes, Claude's live
    /// text stays.
    func hideMeter() {
        guard model.title.hasPrefix("Listening") || model.title == "Starting…" else { return }
        model.showMeter = false
    }

    /// Claude's dictation is being started: grey and "Starting…" until Claude listens, so nobody talks too early.
    func starting() {
        guard model.title.hasPrefix("Listening") else { return }
        model.title = "Starting…"
        model.tint = .gray
        model.icon = "mic"
        model.loading = true
    }

    /// Claude is listening (or the fallback took over): yellow, and the conversation it is listening in.
    func listeningReady(session: String? = nil) {
        if let session, !session.isEmpty { model.footer = session }
        guard model.title == "Starting…" else { return }
        model.loading = false
        model.title = "Listening"
        model.tint = .yellow
        model.icon = "mic.fill"
    }

    /// The live transcript while the handle is squeezed (and while the message is being finalized).
    func partial(_ text: String) {
        guard Settings.shared.hudTranscript, !suppressPartials,
              model.title.hasPrefix("Listening") || model.title.hasSuffix("…") else { return }
        guard text != model.body else { return }
        model.body = text
    }

    /// Queue or draft chosen with a mic button during the squeeze: the highlighted pill moves; nothing else changes.
    func mode(_ label: String) {
        model.intent = label
    }

    /// The message is being finalized: "Sending…", "Adding to draft…" or "Queueing…".
    func sending(_ label: String = "Sending…") {
        model.loading = false
        model.title = label
        model.icon = "arrow.up"
        model.level = -60
        show()
        hide(after: 6)                         // watchdog in case delivery never reports back
    }

    func sent(_ text: String, outcome: String, title: String = "Sent") {
        model.loading = false
        model.title = title
        model.body = Settings.shared.hudTranscript ? text : ""   // the final text, briefly
        model.tint = .green
        model.icon = "checkmark.circle.fill"
        model.level = -60
        show()
        hide(after: model.body.isEmpty ? 0.8 : 1.6)
    }

    func canceled() {
        suppressPartials = true
        model.title = "Canceled"
        model.loading = false
        model.body = ""
        model.footer = ""
        model.tint = .gray
        model.icon = "xmark.circle"
        model.showMeter = false          // nothing is being heard any more
        model.level = -60
        show()
        hide(after: 0.8)
    }

    func flash(_ message: String, detail: String = "", tint: Color = .gray, icon: String = "info.circle", seconds: TimeInterval = 1.6) {
        model.title = message
        model.loading = false
        model.body = detail
        model.footer = ""
        model.showMeter = false
        model.tint = tint
        model.icon = icon
        model.level = -60
        show()
        hide(after: seconds)
    }
}

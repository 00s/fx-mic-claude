import AppKit
import Combine
import SwiftUI
import FXMicCore
import ServiceManagement

final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    enum Activity { case none, thinking, done }
    private var activity: Activity = .none
    private var dotTimer: Timer?
    private var dotPhase = 0
    private var doneReset: DispatchWorkItem?

    /// The mic glyph for a state, with an optional badge in the upper-right corner: dots while the task runs, a check
    /// when it finishes. Template (it follows the menu bar's color) unless a part is lit in its device color.
    private static func compose(part: Int, hungUp: Bool, dark: Bool, dots: Int = 0, check: Bool = false) -> NSImage {
        let side: CGFloat = 20
        let line: Color = dark ? .white : .black          // not a template: the white lower half must stay white
        let ink: NSColor = dark ? .white : .black
        let glyph = MainActor.assumeIsolated { () -> NSImage? in
            let renderer = ImageRenderer(content: MicButtonGlyph(pressed: part, line: line, side: side, solid: true))
            renderer.scale = 2
            return renderer.nsImage
        }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            glyph?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: hungUp ? 0.45 : 1)
            if hungUp {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 2.5))
                slash.line(to: NSPoint(x: side - 3, y: side - 2.5))
                slash.lineWidth = 1.6
                slash.lineCapStyle = .round
                ink.setStroke()
                slash.stroke()
            }
            let ctx = NSGraphicsContext.current
            if dots > 0 {
                let d: CGFloat = 2.6, gap: CGFloat = 1.0
                let x0 = side - 0.5 - (d * 3 + gap * 2)
                let y = side - d - 0.5                                   // upper-right corner
                // knock the badge area out of the handset so the dots read as their own shape
                ctx?.compositingOperation = .destinationOut
                NSColor.black.setFill()
                for i in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(x: x0 + CGFloat(i) * (d + gap), y: y, width: d, height: d).insetBy(dx: -1.1, dy: -1.1)).fill()
                }
                ctx?.compositingOperation = .sourceOver
                ink.setFill()
                for i in 0..<dots {
                    NSBezierPath(ovalIn: NSRect(x: x0 + CGFloat(i) * (d + gap), y: y, width: d, height: d)).fill()
                }
            }
            if check, let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .heavy).applying(.init(paletteColors: [ink]))) {
                let r = NSRect(x: side - mark.size.width - 0.5, y: side - mark.size.height - 0.5, width: mark.size.width, height: mark.size.height)
                mark.draw(in: r.insetBy(dx: -1.4, dy: -1.4), from: .zero, operation: .destinationOut, fraction: 1)
                mark.draw(in: r)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Task-progress decoration on the icon: dots while Claude works, a check for two seconds when it finishes.
    func setActivity(_ a: Activity) {
        activity = a
        dotTimer?.invalidate(); dotTimer = nil
        doneReset?.cancel(); doneReset = nil
        switch a {
        case .thinking:
            dotPhase = 0
            dotTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.dotPhase = (self.dotPhase % 3) + 1
                self.refresh()
            }
        case .done:
            let reset = DispatchWorkItem { [weak self] in self?.setActivity(.none) }
            doneReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: reset)
        case .none:
            break
        }
        refresh()
    }
    private unowned let controller: AppController
    private let menu = NSMenu()
    private var watch: [AnyCancellable] = []
    private lazy var panel = IslandPanelController(controller: controller)

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        // Click opens the panel; right click (or control-click) picks up or hangs up; Option-click shows the plain menu.
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
        controller.onStateChange = { [weak self] in
            self?.refresh()
            if let self { self.controller.live.state = self.controller.state }
        }
        controller.onPanelRequest = { [weak self] in
            guard let self, let button = self.item.button else { return }
            self.panel.toggle(under: button)
        }
        // Queue, draft and shake change the icon too; wait a turn so the new value is in place.
        watch = [
            controller.hud.model.$intent.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() },
            controller.live.$shakeAt.receive(on: RunLoop.main).sink { [weak self] at in
                self?.refresh()
                if at != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self?.refresh() } }
            },
        ]
        controller.dispatcher.onTargetsChanged = { [weak self] in self?.refresh() }
    }

    func refresh() {
        // The same pictures as the island's choices: handle while squeezing, top for queue, middle for draft, motion
        // marks for a shake; the plain mic while waiting, struck through when hung up.
        let model = controller.hud.model
        let shaken = controller.live.shakeAt.map { Date().timeIntervalSince($0) < 1.2 } == true
        let part: Int = shaken ? MicButtonGlyph.shake
            : controller.state != .listening ? MicButtonGlyph.none
            : model.intent == "Queue" ? 0 : model.intent == "Draft" ? 1 : MicButtonGlyph.squeeze
        let dark = item.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hungUp = controller.state == .idle && !controller.usbLiveMain
        func image(dots: Int = 0, check: Bool = false) -> NSImage {
            StatusMenu.compose(part: part, hungUp: hungUp, dark: dark, dots: dots, check: check)
        }
        switch Settings.shared.statusBadge ? activity : .none {
        case .thinking: item.button?.image = image(dots: max(1, dotPhase))
        case .done: item.button?.image = image(check: true)
        case .none: item.button?.image = image()
        }
        item.button?.toolTip = "\(AppName.display): \(controller.state.rawValue). Click for the panel, right-click to \(controller.state == .idle ? "unmute" : "mute")."
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 1. listening toggle
        let toggle = NSMenuItem(title: controller.state == .idle ? "Unmute" : "Mute", action: #selector(toggleArmed), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // 2. input device
        let deviceMenu = NSMenu()
        let currentDevice = Settings.shared.deviceQuery
        for dev in AudioDevices.inputs() {
            let item = NSMenuItem(title: dev.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = dev.name
            item.state = (dev.name == currentDevice || dev.uid == currentDevice || dev.name.localizedCaseInsensitiveContains(currentDevice)) ? .on : .off
            deviceMenu.addItem(item)
        }
        let deviceItem = NSMenuItem(title: "Input device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        // Mic open only while squeezing: needs the mic's USB cable, since without it the tones are the only signal and
        // FXMic must keep the input open to hear them. The line under it says which is happening right now.
        let usbItem = NSMenuItem(title: "Mic open only while squeezing (USB cable)", action: #selector(toggleUSB), keyEquivalent: "")
        usbItem.target = self; usbItem.state = Settings.shared.usbTrigger ? .on : .off
        menu.addItem(usbItem)
        let status: String
        if controller.usbLiveMain { status = "Now: closed between squeezes, over USB" }
        else if Settings.shared.usbTrigger { status = "Now: mic not on USB, listening for tones" }
        else { status = "Now: listening for tones" }
        let trigger = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        trigger.isEnabled = false
        trigger.indentationLevel = 1
        menu.addItem(trigger)
        menu.addItem(.separator())

        // 3. target session, shown by (truncated) name
        let targetMenu = NSMenu()
        // By default messages go to the conversation on screen. Picking one here pins it until unpicked.
        let recent = SessionStore.recent(limit: 5)
        let pin = Settings.shared.targetSessionTitle
        let onScreen = NSMenuItem(title: "Conversation on screen", action: #selector(selectTarget(_:)), keyEquivalent: "")
        onScreen.target = self; onScreen.representedObject = ""
        onScreen.state = pin == nil ? .on : .off
        targetMenu.addItem(onScreen)
        targetMenu.addItem(.separator())
        let header = NSMenuItem(title: "Pin to:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        targetMenu.addItem(header)
        for session in recent {
            let item = NSMenuItem(title: session.title, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = session.title
            item.state = session.title == pin ? .on : .off
            targetMenu.addItem(item)
        }
        let shown = pin.map { "pinned to " + ($0.count > 22 ? String($0.prefix(22)).trimmingCharacters(in: .whitespaces) + "…" : $0) }
            ?? "conversation on screen"
        let targetItem = NSMenuItem(title: "Target: \(shown)", action: nil, keyEquivalent: "")
        targetItem.submenu = targetMenu
        menu.addItem(targetItem)
        menu.addItem(.separator())

        // 4. options
        let shake = NSMenuItem(title: "Shake to cancel", action: #selector(toggleShake), keyEquivalent: "")
        shake.target = self; shake.state = Settings.shared.shakeToCancel ? .on : .off
        menu.addItem(shake)
        let engine = NSMenuItem(title: "Transcribe with Claude's dictation", action: #selector(toggleEngine), keyEquivalent: "")
        engine.target = self; engine.state = Settings.shared.transcriptionEngine == "claude" ? .on : .off
        menu.addItem(engine)
        if Settings.shared.transcriptionEngine == "claude" {
            let fallback = NSMenuItem(title: "Apple's recognizer as fallback", action: #selector(toggleFallback), keyEquivalent: "")
            fallback.target = self; fallback.state = Settings.shared.appleFallback ? .on : .off
            fallback.indentationLevel = 1
            menu.addItem(fallback)
        }
        // Pick-up / hang-up shortcut: shown, re-recorded, or reset from here.
        let shortcutMenu = NSMenu()
        let recordItem = NSMenuItem(title: "Record new shortcut…", action: #selector(recordShortcut), keyEquivalent: "")
        recordItem.target = self
        shortcutMenu.addItem(recordItem)
        let resetItem = NSMenuItem(title: "Reset to ⌘⇧M", action: #selector(resetShortcut), keyEquivalent: "")
        resetItem.target = self
        resetItem.isEnabled = Settings.shared.hotKeyLabel != "⌘⇧M"
        shortcutMenu.addItem(resetItem)
        let shortcutItem = NSMenuItem(title: "Mute shortcut: \(Settings.shared.hotKeyLabel)", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)
        let badge = NSMenuItem(title: "Menu bar activity badge", action: #selector(toggleBadge), keyEquivalent: "")
        badge.target = self; badge.state = Settings.shared.statusBadge ? .on : .off
        menu.addItem(badge)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleIdentifier != nil
        menu.addItem(login)
        if !ComposerDelivery.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility access…", action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        menu.addItem(.separator())

        // 5. quit
        let quitItem = NSMenuItem(title: "Quit \(AppName.display)", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleArmed() { controller.toggleArmed(source: "menu item") }
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.modifierFlags.contains(.option) == true {
            item.menu = menu           // the plain menu, as a fallback; attached only for this click
            sender.performClick(nil)
            item.menu = nil
        } else if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // Muting only means something on the audio cable; on USB a right-click opens the panel like a click.
            if controller.usbLiveMain && controller.state != .idle { panel.toggle(under: sender) }
            else { controller.toggleArmed(source: "menu bar click") }
        } else {
            panel.toggle(under: sender)
        }
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        let title = sender.representedObject as? String ?? ""
        Settings.shared.targetSessionTitle = title.isEmpty ? nil : title
        Log.write("target: \(title.isEmpty ? "conversation on screen" : "pinned: " + title)")
        controller.snapshot()
    }
    @objc private func toggleEngine() {
        Settings.shared.transcriptionEngine = Settings.shared.transcriptionEngine == "claude" ? "apple" : "claude"
        Log.write("transcription engine: \(Settings.shared.transcriptionEngine)")
    }
    private let recorder = ShortcutRecorder()
    @objc private func recordShortcut() {
        let s = Settings.shared
        let old = (s.hotKeyCode, s.hotKeyModifiers, s.hotKeyLabel)
        HotKey.unregister()                       // so pressing the current combination records it instead of toggling
        recorder.record(current: s.hotKeyLabel) { [weak self] result in
            guard let self else { return }
            guard let (code, mods, label) = result else { self.controller.registerHotKey(); return }
            s.hotKeyCode = Int(code); s.hotKeyModifiers = Int(mods); s.hotKeyLabel = label
            if !self.controller.registerHotKey() {
                (s.hotKeyCode, s.hotKeyModifiers, s.hotKeyLabel) = old
                self.controller.registerHotKey()
                self.controller.hud.flash("\(label) is taken", detail: "Another app uses it. Kept \(old.2).", tint: .red,
                                          icon: "keyboard", seconds: 3)
            } else {
                self.controller.hud.flash("Shortcut: \(label)", tint: .blue, icon: "keyboard", seconds: 1.6)
            }
        }
    }
    @objc private func resetShortcut() {
        let s = Settings.shared
        s.hotKeyCode = Int(HotKey.defaultKeyCode); s.hotKeyModifiers = Int(HotKey.defaultModifiers); s.hotKeyLabel = "⌘⇧M"
        controller.registerHotKey()
    }
    @objc private func toggleUSB() {
        Settings.shared.usbTrigger.toggle()
        controller.setUSBTrigger(Settings.shared.usbTrigger)
    }
    @objc private func toggleFallback() {
        Settings.shared.appleFallback.toggle()
        Log.write("apple fallback: \(Settings.shared.appleFallback ? "on" : "off")")
        controller.snapshot()
    }
    @objc private func toggleBadge() { Settings.shared.statusBadge.toggle(); refresh() }
    @objc private func toggleShake() { Settings.shared.shakeToCancel.toggle(); controller.snapshot() }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.shared.deviceQuery = name
        Log.write("input device set to \(name)")
        if controller.state != .idle { controller.disarm(reason: "Switching input") }
        controller.arm()            // picking a device means: listen on it
        refresh()
    }
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            Log.write("launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        } catch { Log.write("launch at login failed: \(error)") }
    }
    @objc private func grantAccessibility() { ComposerDelivery.requestAccess() }
    @objc private func quit() { NSApp.terminate(nil) }
}

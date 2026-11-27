import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon, which needs no Accessibility permission. The combination is a setting, recorded from
/// the menu ("Pick-up shortcut"); the default is Command + Shift + M.
enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    static var action: (() -> Void)?

    static let defaultKeyCode = UInt32(kVK_ANSI_M)
    static let defaultModifiers = UInt32(cmdKey | shiftKey)

    /// Registers (or re-registers) the hotkey. False when macOS refuses it, usually because another app owns it.
    @discardableResult
    static func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        self.action = action
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                HotKey.action?()
                return noErr
            }, 1, &spec, nil, &handler)
        }
        unregister()
        let id = EventHotKeyID(signature: 0x46584D43, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            ref = nil
            NSLog("[fxmic] hotkey not registered (OSStatus %d): another app may own it", status)
            return false
        }
        return true
    }

    static func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Carbon modifier bits from AppKit's.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        return UInt32(m)
    }

    /// How a combination is written in menus: ⌃⌥⇧⌘ then the key.
    static func label(keyCode: UInt32, modifiers: UInt32, character: String?) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let name = named[Int(keyCode)] { return s + name }
        return s + (character?.uppercased() ?? "key \(keyCode)")
    }
}

/// A small window that waits for the next key combination (with at least ⌘, ⌃ or ⌥) and reports it. Esc cancels.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var monitor: Any?
    private var done: ((UInt32, UInt32, String)?) -> Void = { _ in }

    func record(current: String, completion: @escaping ((UInt32, UInt32, String)?) -> Void) {
        done = completion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "FXMic pick-up shortcut"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let text = NSTextField(wrappingLabelWithString: "Press the new shortcut, with ⌘, ⌃ or ⌥.\nNow: \(current)   ·   Esc cancels")
        text.alignment = .center
        text.frame = NSRect(x: 20, y: 30, width: 300, height: 50)
        panel.contentView?.addSubview(text)
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape), flags.isEmpty { self.finish(nil); return nil }
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            let mods = HotKey.carbonModifiers(flags)
            let code = UInt32(event.keyCode)
            self.finish((code, mods, HotKey.label(keyCode: code, modifiers: mods, character: event.charactersIgnoringModifiers)))
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ result: (UInt32, UInt32, String)?) {
        guard window != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let w = window
        window = nil
        w?.close()
        done(result)
    }
}

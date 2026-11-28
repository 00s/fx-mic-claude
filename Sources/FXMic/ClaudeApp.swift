import AppKit
import ApplicationServices
import CoreAudio
import Foundation

/// Talks to the Claude desktop app: bring it forward, go back, open a new Code session.
enum ClaudeApp {
    static let bundleID = "com.anthropic.claudefordesktop"
    private static var previousApp: NSRunningApplication?

    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// True while a Claude process (its dictation runs in a helper process) has an audio input running. Unlike the
    /// dictation control's label, this is right even when Claude's window is hidden, minimized or covered, where its
    /// accessibility values go stale.
    static func isUsingMic() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var running: UInt32 = 0, pid: pid_t = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            a.mSelector = kAudioProcessPropertyPID
            s = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid) == noErr else { continue }
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).contains("/Claude.app/") { return true }
        }
        return false
    }

    /// Claude hidden with ⌘H exposes no usable accessibility tree: no composer text, no Send, no label changes. Show
    /// its windows again without activating it (the current app stays in front) and give them a moment to come back.
    /// True when it had to.
    /// `wait`: give the windows time to come back (off the main thread only; on it, callers that retry anyway, such
    /// as ComposerDelivery.locateComposer, pass false so the UI never stalls).
    @discardableResult
    static func showIfHidden(wait: Bool = true) -> Bool {
        guard let app = running, app.isHidden else { return false }
        app.unhide()
        guard wait, !Thread.isMainThread else { return true }
        for _ in 0..<10 where app.isHidden { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.3)
        return true
    }

    /// Brings Claude to the front; if it is already frontmost, returns to the app that was active before.
    /// Uses a launch request rather than NSRunningApplication.activate, which macOS ignores from background apps.
    static func toggle() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == bundleID {
            if let previous = previousApp, !previous.isTerminated, let url = previous.bundleURL {
                bringForward(url)
            } else {
                running?.hide()
            }
            return
        }
        previousApp = front
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            bringForward(url)
        }
    }

    /// Brings Claude to the front and leaves it there.
    static func show() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { bringForward(url) }
    }

    private static func bringForward(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("[fxmic] activate failed: %@", "\(error)") }
        }
    }

    /// Opens a new Claude Code session in `folder` with the composer prefilled. Presses Return for you when
    /// Accessibility access has been granted, otherwise leaves the prefilled composer for you to send.
    static func newCodeSession(folder: String?, prompt: String) {
        var components = URLComponents(string: "claude://code/new")!
        var items = [URLQueryItem(name: "q", value: prompt)]
        if let folder, !folder.isEmpty { items.append(URLQueryItem(name: "folder", value: folder)) }
        components.queryItems = items
        guard let url = components.url else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.open(url)
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            pressReturn()
        }
    }

    /// Return, delivered to the Claude process only (never system-wide), so it can't land in another app if focus
    /// changes at the last moment.
    static func pressReturn() {
        guard let pid = running?.processIdentifier else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.postToPid(pid)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.postToPid(pid)
    }
}

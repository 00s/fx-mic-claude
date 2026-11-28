import AppKit
import ApplicationServices
import Foundation

/// Watches a Claude session after a message was sent: running means Claude picked it up, idle again means the turn
/// finished. Drives the dots and the check on the menu bar icon.
final class ActivityWatcher {
    enum SessionState { case running, idle, unknown }

    private var thread: Thread?
    private var generation = 0

    func watch(sessionTitle: String, onThinking: @escaping () -> Void, onDone: @escaping () -> Void) {
        generation += 1
        let gen = generation
        thread?.cancel()
        let t = Thread { [weak self] in
            let start = Date()
            var sawRunning = false
            while let self, self.generation == gen, !Thread.current.isCancelled {
                let state = ActivityWatcher.state(of: sessionTitle)
                if !sawRunning {
                    if state == .running {
                        sawRunning = true
                        DispatchQueue.main.async { onThinking() }
                    } else if Date().timeIntervalSince(start) > 20 {
                        Log.write("activity: \(sessionTitle) never showed Running, giving up")
                        return
                    }
                } else if state == .idle {
                    DispatchQueue.main.async { onDone() }
                    return
                } else if Date().timeIntervalSince(start) > 3600 {
                    return
                }
                Thread.sleep(forTimeInterval: sawRunning ? 1.0 : 0.5)
            }
        }
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    func cancel() { generation += 1; thread?.cancel(); thread = nil }

    /// From the session's own file (what queued messages already wait on), which doesn't care how the sidebar looks.
    /// For a conversation without one, its sidebar row, whose label says "Running" while Claude works.
    static func state(of title: String) -> SessionState {
        if let running = SessionStore.isRunning(title: title) { return running ? .running : .idle }
        guard AXIsProcessTrusted(), let app = ClaudeApp.running else { return .unknown }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let windows = (ComposerDelivery.attribute(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let window = windows.first, let row = ComposerDelivery.sidebarRows(titled: title, in: window).first
        else { return .unknown }
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute].map { ComposerDelivery.string(row, $0) }
        let running = labels.contains { $0.hasPrefix("Running ") || $0.hasPrefix("\(title) Running") }
        return running ? .running : .idle
    }
}

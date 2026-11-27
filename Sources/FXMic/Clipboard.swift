import AppKit

/// The last-resort fallback when a message can't be delivered: it goes on the clipboard so it can be pasted, and is
/// cleared again after a minute, so other apps can't read it later. Something copied since then is left alone.
enum Clipboard {
    static func copyBriefly(_ text: String, for seconds: TimeInterval = 60) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        let mark = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard board.changeCount == mark else { return }      // the user copied something else meanwhile
            board.clearContents()
            Log.write("clipboard: cleared the undelivered message after \(Int(seconds)) s")
        }
    }
}

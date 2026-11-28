// Renders the README's images from the app's own views. Run tools/render_docs_images.sh, not this directly.
import AppKit
import SwiftUI

MainActor.assumeIsolated { if CommandLine.arguments.count > 2 { heroImage(CommandLine.arguments[1]) } else { docs(CommandLine.arguments[1]) } }

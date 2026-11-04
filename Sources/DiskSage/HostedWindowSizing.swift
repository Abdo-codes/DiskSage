import AppKit
import SwiftUI

@MainActor
enum HostedWindowSizing {
    static func configure<Content: View>(_ window: NSWindow, content: Content,
        minimum: NSSize, preferred: NSSize, frameName: String, visibleFrame: NSRect? = nil) {
        let hosting = NSHostingController(rootView: content)
        // SwiftUI content changes must scroll inside the window, not resize it.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = minimum
        window.setContentSize(preferred)
        // Registration can itself restore a saved frame; clamp only after it.
        window.setFrameAutosaveName(frameName)
        if !window.setFrameUsingName(frameName) { window.center() }
        let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
        var frame = window.frame
        frame.size.width = max(frame.width, minimumFrame.width)
        frame.size.height = max(frame.height, minimumFrame.height)
        if let screen = visibleFrame ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            frame.size.height = min(frame.height, screen.height)
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
    }
}

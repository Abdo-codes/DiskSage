import AppKit
import SwiftUI

@MainActor
enum ReviewWindowSizing {
    static func configure(_ window: NSWindow, model: AppModel, frameName: String = "CleanupReview") {
        let hosting = NSHostingController(rootView: ReviewView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 800, height: 520)
        window.setContentSize(NSSize(width: 960, height: 660))
        if !window.setFrameUsingName(frameName) { window.center() }
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(NSSize(width: max(800, contentSize.width), height: max(520, contentSize.height)))
        window.setFrameAutosaveName(frameName)
    }
}

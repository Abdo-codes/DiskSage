import AppKit
import SwiftUI

@MainActor
enum ReviewWindowSizing {
    static func configure(_ window: NSWindow, model: AppModel, frameName: String = "CleanupReview") {
        HostedWindowSizing.configure(window, content: ReviewView(model: model),
            minimum: NSSize(width: 800, height: 560), preferred: NSSize(width: 960, height: 660), frameName: frameName)
    }
}

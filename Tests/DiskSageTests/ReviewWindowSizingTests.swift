import AppKit
import Testing
@testable import DiskSage

@MainActor
struct ReviewWindowSizingTests {
    @Test func hostingContentCannotCollapseInitialReviewWindow() throws {
        _ = NSApplication.shared
        let name = "ReviewSizingTest-\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 129, height: 112),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        ReviewWindowSizing.configure(window, model: AppModel(monitoringEnabled: false), frameName: name)
        let size = window.contentRect(forFrameRect: window.frame).size
        // CI displays can be smaller than the preferred window; the window
        // must remain usable while fitting the available screen.
        let screen = try #require(window.screen ?? NSScreen.main)
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        #expect(size.width >= min(960, available.width))
        #expect(size.height >= min(660, available.height))
        #expect(screen.visibleFrame.contains(window.frame))
        #expect(window.contentMinSize.width == 800)
        #expect(window.contentMinSize.height == 560)
        window.close()
    }
}

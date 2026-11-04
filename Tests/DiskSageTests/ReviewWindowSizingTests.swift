import AppKit
import Testing
@testable import DiskSage

@MainActor
struct ReviewWindowSizingTests {
    @Test func hostingContentCannotCollapseInitialReviewWindow() {
        _ = NSApplication.shared
        let name = "ReviewSizingTest-\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 129, height: 112),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        ReviewWindowSizing.configure(window, model: AppModel(monitoringEnabled: false), frameName: name)
        let size = window.contentRect(forFrameRect: window.frame).size
        #expect(size.width >= 960)
        #expect(size.height >= 660)
        #expect(window.contentMinSize.width == 800)
        #expect(window.contentMinSize.height == 520)
        window.close()
    }
}

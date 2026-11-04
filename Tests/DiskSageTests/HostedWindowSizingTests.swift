import AppKit
import SwiftUI
import Testing
@testable import DiskSage

@MainActor
struct HostedWindowSizingTests {
    @Test func intrinsicContentChangesCannotResizeTheHistoryViewport() throws {
        _ = NSApplication.shared
        let name = "HistorySizingTest-\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let window = makeWindow()
        defer { window.close() }
        HostedWindowSizing.configure(window, content: IntrinsicContent(expanded: false),
            minimum: NSSize(width: 620, height: 400), preferred: NSSize(width: 720, height: 520), frameName: name)
        let initial = window.frame
        let size = window.contentRect(forFrameRect: initial).size
        #expect(size == NSSize(width: 720, height: 520))
        let hosting = try #require(window.contentViewController as? NSHostingController<IntrinsicContent>)
        for expanded in [true, false, true] {
            hosting.rootView = IntrinsicContent(expanded: expanded)
            hosting.view.layoutSubtreeIfNeeded()
            #expect(window.frame == initial)
        }
    }

    @Test(arguments: [false, true])
    func badSavedFramesAreRestoredAtAUsableSizeInsideTheVisibleScreen(oversized: Bool) {
        _ = NSApplication.shared
        let name = "HistoryRestoreTest-\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let saved = makeWindow()
        saved.setFrame(NSRect(x: -8_000, y: 8_000, width: oversized ? 3_000 : 82,
                              height: oversized ? 2_500 : 134), display: false)
        saved.saveFrame(usingName: name)
        saved.close()
        let window = makeWindow()
        defer { window.close() }
        let bounds = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        HostedWindowSizing.configure(window, content: Text("History"),
            minimum: NSSize(width: 620, height: 400), preferred: NSSize(width: 720, height: 520),
            frameName: name, visibleFrame: bounds)
        let size = window.contentRect(forFrameRect: window.frame).size
        #expect(size.width >= 620 && size.height >= 400)
        #expect(bounds.contains(window.frame))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 82, height: 134),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct IntrinsicContent: View {
    let expanded: Bool
    var body: some View {
        Text("History content").frame(width: expanded ? 2_000 : 82, height: expanded ? 2_500 : 134)
    }
}

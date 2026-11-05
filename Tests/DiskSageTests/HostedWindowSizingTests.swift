import AppKit
import SwiftUI
import Testing
@testable import DiskSage

@MainActor
struct HostedWindowSizingTests {
    @Test func settingsTabsStayVisibleAtTheDefaultWindowSize() async throws {
        _ = NSApplication.shared
        let name = "SettingsTabsTest-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("mcp", forKey: "settingsSelectedTab")
        let window = makeWindow()
        defer { window.close() }
        let model = AppModel(store: ManagementTestSupport.store())
        let hosting = NSHostingController(rootView: SettingsView(model: model).defaultAppStorage(defaults))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(SettingsView.windowSize)
        for _ in 0..<5 {
            hosting.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        // Modern macOS moves the tabs into a single toolbar item. An undersized
        // window hides every tab behind overflow, including MCP.
        if let toolbar = window.toolbar, !toolbar.items.isEmpty {
            #expect(toolbar.visibleItems?.map(\.itemIdentifier) == toolbar.items.map(\.itemIdentifier))
        }
        #expect(!window.isVisible)
    }

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

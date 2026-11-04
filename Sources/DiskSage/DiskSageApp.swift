import AppKit
import ComposableArchitecture
import SwiftUI

@main
struct DiskSageApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--mcp") {
            MCPServer().run()
            return
        }
        let app = NSApplication.shared
        let delegate = DiskSageAppDelegate(model: AppModel())
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class DiskSageAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let model: AppModel
    private let store: StoreOf<AppFeature>
    private var presentedAgentConfirmationID: UUID?
    private var statusItem: NSStatusItem?
    private var dashboard: DashboardPanelController?
    private var reviewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var agentToolTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        self.store = model.store
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        observe { [weak self] in
            guard let self else { return }
            guard let request = self.store.pendingDeletionRequest, request.trigger == .agent else {
                self.presentedAgentConfirmationID = nil
                return
            }
            guard self.presentedAgentConfirmationID != request.id else { return }
            self.presentedAgentConfirmationID = request.id
            self.showReview()
        }
        do {
            let server = try AgentToolServer { [weak self] request in
                self?.model.handleAgentToolRequest(request) ?? AgentToolReply(error: "DiskSage is shutting down.")
            }
            agentToolTask = Task.detached(priority: .utility) { await server.serve() }
        } catch {
            model.agentToolConnectionError = error.localizedDescription
        }
        dashboard = DashboardPanelController(model: model,
            openReview: { [weak self] in self?.showReview() },
            openSettings: { [weak self] in self?.showSettings() },
            openHistory: { [weak self] in self?.showHistory() })
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.checkmark", accessibilityDescription: "DiskSage")
            button.image?.isTemplate = true
            button.toolTip = "DiskSage — developer storage"
            button.setAccessibilityLabel("DiskSage")
            button.target = self
            button.action = #selector(toggleDashboard(_:))
        }
        statusItem = item
    }

    @objc private func toggleDashboard(_ button: NSStatusBarButton) {
        if dashboard?.isVisible == true {
            dashboard?.hide()
        } else {
            let event = NSApp.currentEvent
            let freshMouse = event.map {
                [.leftMouseUp, .leftMouseDown, .rightMouseUp, .rightMouseDown].contains($0.type) &&
                    abs(ProcessInfo.processInfo.systemUptime - $0.timestamp) < 0.25
            } ?? false
            dashboard?.show(button: button, invocation: freshMouse ? .mouse : .keyboard)
        }
    }

    @objc private func showReview() {
        dashboard?.hide()
        if reviewWindow == nil {
            let window = makeWindow(title: "DiskSage Review", width: 960, height: 660, resizable: true)
            ReviewWindowSizing.configure(window, model: model)
            reviewWindow = window
        }
        reviewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func cleanLowRiskItems() {
        showReview()
        model.requestLowRiskCleanup()
    }

    @objc private func showSettings() {
        dashboard?.hide()
        if settingsWindow == nil {
            let window = makeWindow(title: "DiskSage Settings", width: 600, height: 540, resizable: false)
            window.contentViewController = NSHostingController(rootView:
                SettingsView(model: model))
            window.setContentSize(NSSize(width: 600, height: 540))
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAgentSettings() {
        UserDefaults.standard.set("agent", forKey: "settingsSelectedTab")
        showSettings()
    }

    private func makeWindow(title: String, width: CGFloat, height: CGFloat, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    @objc func showHistory() {
        dashboard?.hide()
        model.refreshDashboard()
        if historyWindow == nil {
            let window = makeWindow(title: "DiskSage Cleanup History", width: 720, height: 520, resizable: true)
            HostedWindowSizing.configure(window, content: CleanupHistoryView(model: model),
                minimum: NSSize(width: 620, height: 400), preferred: NSSize(width: 720, height: 520),
                frameName: "CleanupHistory")
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(cleanLowRiskItems) { return model.dashboardPresentation.canCleanNow }
        if menuItem.action == #selector(quitApplication) { return !model.isCleaning }
        return true
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "DiskSage")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let history = NSMenuItem(title: "Cleanup History…", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        appMenu.addItem(history)
        let clean = NSMenuItem(title: "Clean Low-Risk Items…", action: #selector(cleanLowRiskItems), keyEquivalent: "")
        clean.target = self
        appMenu.addItem(clean)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit DiskSage", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let review = NSMenuItem(title: "Cleanup Review…", action: #selector(showReview), keyEquivalent: "1")
        review.target = self
        fileMenu.addItem(review)
        let fileClean = NSMenuItem(title: "Clean Low-Risk Items…", action: #selector(cleanLowRiskItems), keyEquivalent: "")
        fileClean.target = self
        fileMenu.addItem(fileClean)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        for screen in NSScreen.screens {
            let item = NSMenuItem(title: "Dashboard on \(screen.localizedName)",
                                  action: #selector(showDashboardOnDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            windowMenu.addItem(item)
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showDashboardOnDisplay(_ item: NSMenuItem) {
        guard let displayID = item.representedObject as? NSNumber,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == displayID
              }), let button = statusItem?.button else { return }
        dashboard?.show(button: button, invocation: .reopen, on: screen)
    }

    @objc func quitApplication() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.isCleaning else {
            model.errorMessage = "Cleanup is still running. Wait for it to finish before quitting DiskSage."
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { agentToolTask?.cancel() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = [reviewWindow, settingsWindow, historyWindow].compactMap({ $0 }).first(where: { $0.isVisible }) {
            dashboard?.hide()
            (window.attachedSheet ?? window).makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if dashboard?.isVisible == true {
            dashboard?.focus()
        } else if let button = statusItem?.button {
            dashboard?.show(button: button, invocation: .reopen)
        }
        return false
    }
}

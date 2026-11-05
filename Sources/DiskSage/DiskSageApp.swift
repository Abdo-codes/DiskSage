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
        let showOnboarding = MCPOnboardingPreferences.shouldAutoShow(hasExistingData: MCPOnboardingPreferences.hasExistingData)
        let delegate = DiskSageAppDelegate(model: AppModel(), showOnboardingAtLaunch: showOnboarding)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class DiskSageAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    private let model: AppModel
    private let store: StoreOf<AppFeature>
    private var presentedAgentConfirmationID: UUID?
    private var statusItem: NSStatusItem?
    private var dashboard: DashboardPanelController?
    private var reviewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var agentToolTask: Task<Void, Never>?
    private var managementWindow: NSWindow?
    private var presentedManagementID: UUID?
    private var onboardingWindow: NSWindow?
    private let showOnboardingAtLaunch: Bool

    init(model: AppModel, showOnboardingAtLaunch: Bool = false) {
        self.model = model
        self.store = model.store
        self.showOnboardingAtLaunch = showOnboardingAtLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(openToolWindow(_:)), name: .diskSageOpenWindow, object: nil)
        observe { [weak self] in self?.presentManagementApproval() }
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
        if showOnboardingAtLaunch { showOnboarding(startAt: .welcome) }
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
            let size = SettingsView.windowSize
            let window = makeWindow(title: "DiskSage Settings", width: size.width, height: size.height, resizable: false)
            window.contentViewController = NSHostingController(rootView:
                SettingsView(model: model))
            window.setContentSize(size)
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
        let about = NSMenuItem(title: "About DiskSage…", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
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

    @objc private func showAbout() {
        UserDefaults.standard.set("about", forKey: "settingsSelectedTab")
        showSettings()
    }

    private func showOnboarding(startAt step: MCPOnboardingView.Step = .connect) {
        dashboard?.hide()
        let window = onboardingWindow ?? makeWindow(title: "DiskSage Setup", width: 640, height: 600, resizable: true)
        window.delegate = self
        HostedWindowSizing.configure(window, content: MCPOnboardingView(model: model, initialStep: step,
            finish: { [weak self] in self?.finishOnboarding() }, openGeneralSettings: { [weak self] in
                self?.finishOnboarding()
                UserDefaults.standard.set("general", forKey: "settingsSelectedTab")
                self?.showSettings()
            }), minimum: NSSize(width: 600, height: 500), preferred: NSSize(width: 640, height: 600), frameName: "Onboarding")
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishOnboarding() {
        MCPOnboardingPreferences.complete()
        onboardingWindow?.orderOut(nil)
    }

    private func presentManagementApproval() {
        guard let request = model.pendingManagementApproval else {
            presentedManagementID = nil
            managementWindow?.orderOut(nil)
            return
        }
        guard presentedManagementID != request.id else { return }
        presentedManagementID = request.id
        dashboard?.hide()
        let window = managementWindow ?? makeWindow(title: "DiskSage Agent Request", width: 600, height: 440, resizable: true)
        window.delegate = self
        HostedWindowSizing.configure(window, content: ManagementApprovalView(request: request,
            approve: { [weak self] in self?.store.send(.approveManagement(request.id)) },
            reject: { [weak self] in self?.store.send(.rejectManagement(request.id)) }),
            minimum: NSSize(width: 520, height: 360), preferred: NSSize(width: 600, height: 440), frameName: "AgentApproval")
        managementWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === onboardingWindow { finishOnboarding() }
        if notification.object as? NSWindow === managementWindow, let id = model.pendingManagementApproval?.id {
            store.send(.rejectManagement(id))
        }
    }

    @objc private func openToolWindow(_ notification: Notification) {
        switch notification.object as? String {
        case "review": showReview()
        case "history": showHistory()
        case "settings": showSettings()
        case "tools":
            UserDefaults.standard.set("mcp", forKey: "settingsSelectedTab")
            showSettings()
        case "schedules", "agent", "mcp", "general", "about":
            UserDefaults.standard.set(notification.object as? String, forKey: "settingsSelectedTab")
            showSettings()
        case "onboarding": showOnboarding()
        case "dashboard":
            if let button = statusItem?.button { dashboard?.show(button: button, invocation: .reopen) }
        default: break
        }
    }

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
        if let window = [managementWindow, onboardingWindow, reviewWindow, settingsWindow, historyWindow].compactMap({ $0 }).first(where: { $0.isVisible }) {
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

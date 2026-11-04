import AppKit
import OSLog
import SwiftUI

@MainActor
final class DashboardPanelController {
    private let model: AppModel
    private let openReview: () -> Void
    private let openSettings: () -> Void
    private let openHistory: () -> Void
    private let panel = DashboardPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private var hosting: DashboardHostingView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var currentScreen: NSScreen?
    private var anchorX: CGFloat = 0
    private var heightLimited = false
    private var layingOut = false
    private var observers: [NSObjectProtocol] = []
    private var accessibilityObserver: NSObjectProtocol?
    private let presentationLog = Logger(subsystem: "com.abdoeaita.DiskSage", category: "Presentation")
    private var lastAnchors: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "dashboardAnchorOffsets") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "dashboardAnchorOffsets") }
    }

    var isVisible: Bool { panel.isVisible }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    init(model: AppModel, openReview: @escaping () -> Void,
         openSettings: @escaping () -> Void, openHistory: @escaping () -> Void) {
        self.model = model
        self.openReview = openReview
        self.openSettings = openSettings
        self.openHistory = openHistory
        panel.title = "DiskSage Dashboard"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.cancel = { [weak self] in self?.hide() }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            })
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
    }

    func show(button: NSStatusBarButton, invocation: PopupPlacement.Invocation, on requestedScreen: NSScreen? = nil) {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let iconRect = button.accessibilityFrame()
        guard let index = PopupPlacement.screenIndex(frames: screens.map(\.frame), pointer: mouse,
                                                     iconRect: iconRect, invocation: invocation) else { return }
        let screen = requestedScreen ?? screens[index]
        currentScreen = screen
        let key = String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName)
        if invocation == .mouse {
            anchorX = mouse.x
            lastAnchors[key] = Double(screen.frame.maxX - mouse.x)
        } else if let offset = lastAnchors[key] {
            anchorX = screen.frame.maxX - CGFloat(offset)
        } else {
            let onThisMenuBar = iconRect.midX >= screen.frame.minX && iconRect.midX <= screen.frame.maxX &&
                iconRect.midY >= screen.visibleFrame.maxY && iconRect.midY <= screen.frame.maxY + 2
            anchorX = onThisMenuBar ? iconRect.midX : screen.visibleFrame.maxX - 24
        }
        model.refreshDashboard()
        if model.lastScanDate == nil && !model.isBusy { model.scan() }
        heightLimited = false
        let view = DashboardHostingView(rootView: makeView(heightLimit: nil))
        hosting = view
        let naturalSize = view.fittingSize
        let frame = PopupPlacement.frame(size: naturalSize, anchorX: anchorX, visibleFrame: screen.visibleFrame)
        if naturalSize.height > frame.height {
            heightLimited = true
            view.rootView = makeView(heightLimit: frame.height)
        }
        installSurface(view, size: frame.size)
        panel.setFrame(frame, display: true)
        view.sizeChanged = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.resizeIfNeeded() }
        }
        focus()
        recordPresentation(on: screen)
        installDismissalMonitors()
    }

    func hide() {
        panel.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func makeView(heightLimit: CGFloat?) -> MenuBarView {
        MenuBarView(model: model, heightLimit: heightLimit, openReview: openReview,
                    openSettings: openSettings, openHistory: openHistory)
    }

    private func installSurface(_ view: NSView, size: NSSize) {
        panel.contentView = DashboardSurfaceView(content: view, size: size)
    }

    private func resizeIfNeeded() {
        guard panel.isVisible, !layingOut, !heightLimited, let hosting, let currentScreen else { return }
        layingOut = true
        defer { layingOut = false }
        let size = hosting.fittingSize
        let frame = PopupPlacement.frame(size: size, anchorX: anchorX, visibleFrame: currentScreen.visibleFrame)
        if size.height > frame.height {
            heightLimited = true
            hosting.rootView = makeView(heightLimit: frame.height)
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private func installDismissalMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let point = NSEvent.mouseLocation
            let inOwnButton = self.currentScreen.map {
                $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY && abs(point.x - self.anchorX) < 16
            } ?? false
            if event.window !== self.panel && !self.panel.frame.contains(point) && !inOwnButton && self.panel.attachedSheet == nil {
                self.hide()
            }
            return event
        }
    }

    private func recordPresentation(on screen: NSScreen) {
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]] ?? []
        let window = windows.first { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
        let bounds = window?[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: bounds, options: [.sortedKeys])) ?? Data()
        let geometry = String(decoding: data, as: UTF8.self)
        let visible = NSStringFromRect(screen.visibleFrame)
        presentationLog.notice("dashboardShown display=\(screen.localizedName, privacy: .public) windowServerBounds=\(geometry, privacy: .public) visibleFrame=\(visible, privacy: .public)")
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}

@MainActor
private final class DashboardPanel: NSPanel {
    var cancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

@MainActor
private final class DashboardHostingView: NSHostingView<MenuBarView> {
    var sizeChanged: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        sizeChanged?()
    }
}

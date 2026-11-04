import AppKit

/// Clips the entire composited popup, including the glass backing, to its window shape.
@MainActor
final class DashboardSurfaceView: NSView {
    override var isOpaque: Bool { false }

    init(content: NSView, size: NSSize,
         reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
        super.init(frame: NSRect(origin: .zero, size: size))
        let surface: NSView
        let radius: CGFloat
        content.frame = bounds
        content.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *), !reduceTransparency {
            let glass = NSGlassEffectView(frame: bounds)
            radius = 18
            glass.cornerRadius = radius
            glass.contentView = content
            surface = glass
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            radius = 14
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(content)
            surface = effect
        }

        // The glass rounds its own material; its enclosing backing must also be clipped.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
    }

    required init?(coder: NSCoder) { nil }
}

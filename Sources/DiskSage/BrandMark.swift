import AppKit
import CoreGraphics
import SwiftUI

/// Renders DiskSage's custom menu-bar template glyph and resolves the application icon
/// cleanly for both bundled `.app` builds and unbundled SwiftPM runs.
enum BrandMark {
    static let menuBarSize = NSSize(width: 18, height: 18)

    /// Monochrome template glyph for the macOS menu bar echoing DiskSage's inlaid storage ring and sage leaf.
    static func menuBarIcon(size: NSSize = menuBarSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawGlyph(in: ctx, rect: rect, tint: NSColor.black.cgColor)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DiskSage"
        return image
    }

    /// Returns the bundled macOS application icon (`Assets.car` / `AppIcon.icns`), or a rendered vector badge in bare SwiftPM runs.
    static func applicationIcon(bundle: Bundle = .main) -> NSImage {
        if bundle == .main, hasBundledIcon(in: bundle), let bundled = NSImage(named: NSImage.applicationIconName) {
            return bundled
        }
        if let icns = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let loaded = NSImage(contentsOf: icns) {
            return loaded
        }
        return fallbackApplicationIcon()
    }

    /// Clean vector badge used when running outside a `.app` bundle (for example `swift run` or unit tests).
    static func fallbackApplicationIcon(size: NSSize = NSSize(width: 128, height: 128)) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard rect.width > 0, rect.height > 0,
                  let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let inset = rect.width * 0.08
            let tile = rect.insetBy(dx: inset, dy: inset)
            let radius = tile.width * 0.225
            let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let top = CGColor(colorSpace: srgb, components: [0.129, 0.329, 0.247, 1])!
            let bottom = CGColor(colorSpace: srgb, components: [0.027, 0.102, 0.075, 1])!
            if let gradient = CGGradient(colorsSpace: srgb, colors: [top, bottom] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: tile.minX, y: tile.maxY),
                                       end: CGPoint(x: tile.maxX, y: tile.minY),
                                       options: [])
            }
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(colorSpace: srgb, components: [0.72, 0.88, 0.80, 0.42])!)
            ctx.setLineWidth(max(1, tile.width * 0.018))
            ctx.strokePath()
            ctx.restoreGState()

            let glyphRect = tile.insetBy(dx: tile.width * 0.18, dy: tile.height * 0.18)
            drawGlyph(in: ctx, rect: glyphRect,
                      tint: CGColor(colorSpace: srgb, components: [0.89, 0.96, 0.92, 1])!)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "DiskSage"
        return image
    }

    private static func hasBundledIcon(in bundle: Bundle) -> Bool {
        bundle.object(forInfoDictionaryKey: "CFBundleIconName") != nil
            || bundle.object(forInfoDictionaryKey: "CFBundleIconFile") != nil
            || bundle.url(forResource: "AppIcon", withExtension: "icns") != nil
    }

    private static func drawGlyph(in ctx: CGContext, rect: CGRect, tint: CGColor) {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return }
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        let scale = side / 18.0

        ctx.saveGState()
        ctx.translateBy(x: originX, y: originY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // Open storage gauge ring (echoing the inlaid dial on DiskSage's app icon).
        let center = CGPoint(x: 9.0, y: 9.0)
        let radius: CGFloat = 7.3
        ctx.setStrokeColor(tint)
        ctx.setLineWidth(1.65)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius,
                   startAngle: 82 * .pi / 180, endAngle: 10 * .pi / 180, clockwise: false)
        ctx.strokePath()

        // Active reclaimed-capacity indicator dot in the open top-right quadrant.
        ctx.setFillColor(tint)
        let dotAngle: CGFloat = 46 * .pi / 180
        let dotCenter = CGPoint(x: center.x + cos(dotAngle) * radius, y: center.y + sin(dotAngle) * radius)
        ctx.fillEllipse(in: CGRect(x: dotCenter.x - 1.0, y: dotCenter.y - 1.0, width: 2.0, height: 2.0))

        // Sculpted sage leaf with negative-space midrib vein cutout.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: 6.2, y: 6.2))
        leaf.addCurve(to: CGPoint(x: 12.2, y: 12.2),
                      control1: CGPoint(x: 5.5, y: 9.7),
                      control2: CGPoint(x: 8.3, y: 12.3))
        leaf.addCurve(to: CGPoint(x: 6.2, y: 6.2),
                      control1: CGPoint(x: 12.3, y: 8.3),
                      control2: CGPoint(x: 9.7, y: 5.5))
        leaf.closeSubpath()
        ctx.addPath(leaf)
        ctx.setFillColor(tint)
        ctx.fillPath()

        ctx.setStrokeColor(tint)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 6.4, y: 6.4))
        ctx.addLine(to: CGPoint(x: 5.4, y: 5.4))
        ctx.strokePath()

        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1.0)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 7.2, y: 7.2))
        ctx.addLine(to: CGPoint(x: 10.4, y: 10.4))
        ctx.strokePath()
        ctx.endTransparencyLayer()

        ctx.restoreGState()
    }
}

/// Displays DiskSage's macOS application icon cleanly inside SwiftUI headers and identity cards.
struct BrandIconBadge: View {
    var size: CGFloat = 32
    var icon: NSImage = BrandMark.applicationIcon()

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

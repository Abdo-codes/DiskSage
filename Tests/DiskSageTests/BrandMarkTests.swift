import AppKit
import CoreGraphics
import Testing
@testable import DiskSage

struct BrandMarkTests {
    @Test func menuBarIconRendersCrispTemplateGlyphWithNonEmptyPixels() throws {
        let icon = BrandMark.menuBarIcon()
        #expect(icon.isTemplate)
        #expect(icon.size == BrandMark.menuBarSize)
        #expect(icon.accessibilityDescription == "DiskSage")

        // Rasterize at 2x Retina into an RGBA buffer and verify actual glyph ink is drawn.
        let pixels = try rasterizeNonEmptyAlphaCount(icon, width: 36, height: 36)
        #expect(pixels > 80)
        #expect(pixels < 36 * 36)
    }

    @Test func fallbackApplicationIconRendersBadgeWhenUnbundled() throws {
        let icon = BrandMark.fallbackApplicationIcon()
        #expect(!icon.isTemplate)
        #expect(icon.size == NSSize(width: 128, height: 128))
        #expect(icon.accessibilityDescription == "DiskSage")

        let pixels = try rasterizeNonEmptyAlphaCount(icon, width: 128, height: 128)
        #expect(pixels > 5_000)
        #expect(pixels < 128 * 128)
    }

    private func rasterizeNonEmptyAlphaCount(_ image: NSImage, width: Int, height: Int) throws -> Int {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        var nonZero = 0
        for index in stride(from: 3, to: bytes.count, by: 4) where bytes[index] > 16 {
            nonZero += 1
        }
        return nonZero
    }
}

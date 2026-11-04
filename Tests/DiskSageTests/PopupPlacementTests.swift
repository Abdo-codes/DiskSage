import Foundation
import Testing
@testable import DiskSage

struct PopupPlacementTests {
    static let displays = [
        CGRect(x: 0, y: 0, width: 3360, height: 1388),
        CGRect(x: -1080, y: -207, width: 1080, height: 1890),
        CGRect(x: 3360, y: -180, width: 1080, height: 1890)
    ]

    @Test(arguments: displays, [0.01, 0.5, 0.99])
    func popupFitsTheIntendedDisplay(visibleFrame: CGRect, fraction: Double) {
        let anchorX = visibleFrame.minX + visibleFrame.width * fraction
        let frame = PopupPlacement.frame(size: CGSize(width: 368, height: 520),
                                         anchorX: anchorX, visibleFrame: visibleFrame)
        #expect(visibleFrame.insetBy(dx: 8, dy: 8).contains(frame))
        #expect(frame.width == 368)
        #expect(frame.maxY == visibleFrame.maxY - 8)
        if fraction == 0.5 { #expect(abs(frame.midX - anchorX) < 0.001) }
    }

    @Test
    func staleAnchorAndTallContentCannotPutPopupIntoDisplayGap() {
        let visible = Self.displays[0]
        let frame = PopupPlacement.frame(size: CGSize(width: 368, height: 2000),
                                         anchorX: -20, visibleFrame: visible)
        #expect(visible.insetBy(dx: 8, dy: 8).contains(frame))
        #expect(frame.minX == 8)
        #expect(frame.height == visible.height - 16)
    }

    @Test
    func keyboardActivationUsesTheFocusedIconRatherThanPointerDisplay() {
        let frames = [CGRect(x: 0, y: 0, width: 3360, height: 1418),
                      CGRect(x: -1080, y: -207, width: 1080, height: 1920)]
        let pointer = CGPoint(x: -500, y: 1000)
        let icon = CGRect(x: 2080, y: 1388, width: 30, height: 30)
        #expect(PopupPlacement.screenIndex(frames: frames, pointer: pointer, iconRect: icon, invocation: .keyboard) == 0)
        #expect(PopupPlacement.screenIndex(frames: frames, pointer: pointer, iconRect: icon, invocation: .mouse) == 1)
        #expect(PopupPlacement.screenIndex(frames: frames, pointer: pointer, iconRect: icon, invocation: .reopen) == 1)
    }
}

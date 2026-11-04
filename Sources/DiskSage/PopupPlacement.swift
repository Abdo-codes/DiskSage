import Foundation

enum PopupPlacement {
    enum Invocation { case mouse, keyboard, reopen }

    static func screenIndex(frames: [CGRect], pointer: CGPoint, iconRect: CGRect, invocation: Invocation) -> Int? {
        guard !frames.isEmpty else { return nil }
        let iconIndex = frames.firstIndex {
            iconRect.width > 0 && iconRect.height > 0 && $0.contains(CGPoint(x: iconRect.midX, y: iconRect.midY)) &&
                iconRect.minY >= $0.maxY - 40
        }
        if invocation == .keyboard { return iconIndex ?? 0 }
        return frames.firstIndex { $0.contains(pointer) } ?? iconIndex ?? 0
    }

    static func frame(size: CGSize, anchorX: CGFloat, visibleFrame: CGRect) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(max(1, size.width), max(1, bounds.width))
        let height = min(max(1, size.height), max(1, bounds.height))
        let x = min(max(anchorX - width / 2, bounds.minX), bounds.maxX - width)
        return CGRect(x: x, y: bounds.maxY - height, width: width, height: height)
    }
}

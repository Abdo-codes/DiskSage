import AppKit
import SwiftUI

enum DashboardTheme {
    static let muted = Color(nsColor: .labelColor).opacity(0.9)
    static let readingSurface = Color(nsColor: .windowBackgroundColor).opacity(0.86)
    /// Signature DiskSage botanical sage-emerald accent, tuned for legibility in both Light and Dark appearances.
    static let brandSage = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.298, green: 0.878, blue: 0.620, alpha: 1)
            : NSColor(srgbRed: 0.106, green: 0.478, blue: 0.322, alpha: 1)
    })
    static let brandSpruce = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.114, green: 0.302, blue: 0.227, alpha: 1)
            : NSColor(srgbRed: 0.067, green: 0.247, blue: 0.176, alpha: 1)
    })
    static let mint = brandSage
    static let blue = Color.accentColor
    static let amber = Color.orange
    static let violet = Color.purple

    static func color(for category: CandidateCategory) -> Color {
        switch category {
        case .cache: mint
        case .build: blue
        case .archive: amber
        case .simulator: violet
        }
    }
}

struct DashboardActionStyle: ViewModifier {
    var prominent = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

import SwiftUI

enum DashboardTheme {
    static let muted = Color.secondary
    static let mint = Color.green
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

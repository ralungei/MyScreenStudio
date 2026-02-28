import SwiftUI

// MARK: - Modern Button Component
struct ModernButton: View {
    let title: String
    let icon: String?
    let style: ModernButtonStyle
    let action: () -> Void
    let isDisabled: Bool

    init(_ title: String, icon: String? = nil, style: ModernButtonStyle = .primary, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.action = action
        self.isDisabled = disabled
    }

    var body: some View {
        let button = Button {
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: style.iconSize, weight: style.iconWeight))
                }

                Text(title)
                    .fontWeight(style.fontWeight)
            }
            .padding(.horizontal, style.horizontalPadding)
            .padding(.vertical, style.verticalPadding)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)

        switch style {
        case .primary:
            button
                .buttonStyle(.glassProminent)
                .tint(Color(hex: "A4EB3F"))
        case .secondary:
            button
                .buttonStyle(.glass)
        case .destructive:
            button
                .buttonStyle(.glass)
                .tint(.red)
        }
    }
}

// MARK: - Modern Button Style
enum ModernButtonStyle {
    case primary
    case secondary
    case destructive

    var horizontalPadding: CGFloat {
        switch self {
        case .primary: return 24
        case .secondary: return 20
        case .destructive: return 20
        }
    }

    var verticalPadding: CGFloat { 8 }

    var fontWeight: Font.Weight {
        switch self {
        case .primary: return .medium
        case .secondary: return .regular
        case .destructive: return .medium
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .primary: return 14
        case .secondary: return 13
        case .destructive: return 13
        }
    }

    var iconWeight: Font.Weight {
        switch self {
        case .primary: return .medium
        case .secondary: return .regular
        case .destructive: return .medium
        }
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 16) {
        ModernButton("Primary Button", icon: "play.fill", style: .primary) {
            print("Primary tapped")
        }

        ModernButton("Secondary Button", icon: "gear", style: .secondary) {
            print("Secondary tapped")
        }

        ModernButton("Destructive Button", icon: "trash", style: .destructive) {
            print("Destructive tapped")
        }

        ModernButton("Disabled Button", style: .primary, disabled: true) {
            print("This won't print")
        }
    }
    .padding()
}

import SwiftUI
import AppKit

// MARK: - Editor Header

struct EditorHeaderView: View {
    let projectName: String
    @Binding var inspectorCollapsed: Bool
    let onCrop: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Title centered between leading edge and inspector toggle
            Spacer()

            Text(projectName)
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            // Inspector toggle — circular glass
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { inspectorCollapsed.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .circle)

            ModernButton("Crop", icon: "crop", style: .secondary) {
                onCrop()
            }

            ModernButton("Export", icon: "square.and.arrow.up", style: .primary) {
                onExport()
            }
        }
        .padding(.leading, 78) // space for 🔴🟡🟢 traffic lights
        .padding(.trailing, 16)
        .padding(.vertical, 8)
    }
}

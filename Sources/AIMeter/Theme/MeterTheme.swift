import SwiftUI

/// Shared visual design tokens used across the popover UI.
enum MeterTheme {
    static let popoverWidth: CGFloat = 312
    static let healthyGreen = Color(red: 0.13, green: 0.68, blue: 0.43)

    static func quotaColor(for remaining: Int) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 35 { return .orange }
        return healthyGreen
    }

    static var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }

    static var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    static func sectionHeaderLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
    }
}

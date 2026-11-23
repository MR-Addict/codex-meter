import SwiftUI

/// Clean circular header button with subtle tactile press state and zero focus-ring clutter.
struct HeaderIconButton: View {
    let symbol: String
    let help: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(CircleIconButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06))
            )
            .contentShape(Circle())
    }
}

struct InlineActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI
import MeterCore

/// Bare vector service icon rendered at any size/tint (for switcher pills & badges).
struct ServiceMarkView: View {
    let serviceID: ServiceID?
    var size: CGFloat = 13

    var body: some View {
        let appearance = ServiceAppearance.resolve(serviceID)
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            appearance.drawInCanvas(&context, rect: rect, size: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Rounded brand squircle badge used in the popover header and service rows.
struct ServiceBadgeView: View {
    let serviceID: ServiceID?
    var size: CGFloat = 26

    var body: some View {
        let appearance = ServiceAppearance.resolve(serviceID)
        let cornerRadius = size * 0.28
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(appearance.badgeGradient)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(appearance.borderOpacity), lineWidth: 0.75)
            )
            .overlay(
                ServiceMarkView(serviceID: serviceID, size: size * 0.58)
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
    }
}

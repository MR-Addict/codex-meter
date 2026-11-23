import SwiftUI
import AppKit
import MeterCore

/// Custom vector brand marks shared identically across the macOS menu bar,
/// popover header badges, service switcher pills, and inline Settings.
enum ServiceMenuBarIcon {
    static func makeTemplateImage(for kind: ServiceIconKind) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setStroke()
            NSColor.black.setFill()
            draw(kind: kind, in: rect.insetBy(dx: 0.75, dy: 0.75), context: ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(kind: ServiceIconKind, in rect: CGRect, context: CGContext) {
        switch kind {
        case .codex:
            let cgPath = codexPath(in: rect).cgPath
            context.addPath(cgPath)
            context.setLineWidth(max(1.1, rect.width * 0.088))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        case .antigravity:
            let cgPath = antigravityPath(in: rect).cgPath
            context.addPath(cgPath)
            context.fillPath()
        case .generic:
            let cgPath = genericGaugePath(in: rect).cgPath
            context.addPath(cgPath)
            context.setLineWidth(max(1.2, rect.width * 0.095))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            let hubSize = rect.width * 0.16
            let hubRect = CGRect(
                x: rect.midX - hubSize / 2,
                y: rect.minY + rect.height * 0.56 - hubSize / 2,
                width: hubSize,
                height: hubSize
            )
            context.fillEllipse(in: hubRect)
        }
    }

    /// 6-petal interlocking geometric rosette knot (OpenAI / Codex silhouette).
    /// Computed analytically in a 24×24 coordinate space so all 6 strands meet cleanly.
    static func codexPath(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 20.6
        let center = CGPoint(x: rect.midX, y: rect.midY)

        // Exact geometric constants: apothem a = 2.65, arc radius R = 3.95
        let a: CGFloat = 2.65
        let r: CGFloat = 3.95
        let cx: CGFloat = a - r          // -1.30
        let cy: CGFloat = -4.85
        let vy: CGFloat = a / sqrt(3)    //  1.53 (inner hexagon vertex)
        let endAngleRad: CGFloat = 185.53 * .pi / 180.0

        var combined = Path()
        for k in 0..<6 {
            let theta = CGFloat(k) * (.pi / 3.0)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: theta)
                .scaledBy(x: scale, y: scale)

            var strand = Path()
            strand.move(to: CGPoint(x: a, y: vy))
            strand.addLine(to: CGPoint(x: a, y: cy))
            strand.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: r,
                startAngle: .radians(0),
                endAngle: .radians(-Double(endAngleRad)),
                clockwise: true
            )
            combined.addPath(strand.applying(transform))
        }
        return combined
    }

    /// Symmetrical levitating stylized "A" arch with flared downward tips (Google Antigravity mark).
    static func antigravityPath(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24.0
        let ox = rect.midX - 12.0 * s
        let oy = rect.midY - 12.0 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }

        var path = Path()
        // Outer levitating arch (bottom-left tip -> rounded apex -> bottom-right tip)
        path.move(to: pt(4.0, 20.1))
        path.addCurve(to: pt(12.0, 3.3), control1: pt(6.2, 13.6), control2: pt(8.9, 3.3))
        path.addCurve(to: pt(20.0, 20.1), control1: pt(15.1, 3.3), control2: pt(17.8, 13.6))
        // Soft rounded right tip into the floating inner arch
        path.addCurve(to: pt(17.2, 20.3), control1: pt(20.2, 20.9), control2: pt(18.2, 21.1))
        path.addCurve(to: pt(12.0, 12.7), control1: pt(15.6, 17.6), control2: pt(14.1, 12.7))
        path.addCurve(to: pt(6.8, 20.3), control1: pt(9.9, 12.7), control2: pt(8.4, 17.6))
        // Soft rounded left tip closing cleanly
        path.addCurve(to: pt(4.0, 20.1), control1: pt(5.8, 21.1), control2: pt(3.8, 20.9))
        path.closeSubpath()
        return path
    }

    /// Minimalist gauge arc + needle for the neutral 0-service state.
    static func genericGaugePath(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24.0
        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.56)
        var path = Path()
        path.addArc(
            center: center,
            radius: 8.6 * s,
            startAngle: .degrees(155),
            endAngle: .degrees(25),
            clockwise: false
        )
        path.move(to: center)
        path.addLine(to: CGPoint(x: center.x + 4.4 * s, y: center.y - 4.8 * s))
        return path
    }
}

/// Bare vector service icon rendered at any size/tint (for switcher pills & inline Settings).
struct ServiceMarkView: View {
    let kind: ServiceIconKind
    var size: CGFloat = 13

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            switch kind {
            case .codex:
                let path = ServiceMenuBarIcon.codexPath(in: rect)
                context.stroke(
                    path,
                    with: .foreground,
                    style: StrokeStyle(lineWidth: max(1.0, size * 0.092), lineCap: .round, lineJoin: .round)
                )
            case .antigravity:
                let path = ServiceMenuBarIcon.antigravityPath(in: rect)
                context.fill(path, with: .foreground)
            case .generic:
                let path = ServiceMenuBarIcon.genericGaugePath(in: rect)
                context.stroke(
                    path,
                    with: .foreground,
                    style: StrokeStyle(lineWidth: max(1.1, size * 0.10), lineCap: .round, lineJoin: .round)
                )
                let hub = size * 0.16
                let hubRect = CGRect(
                    x: rect.midX - hub / 2,
                    y: rect.height * 0.56 - hub / 2,
                    width: hub,
                    height: hub
                )
                context.fill(Path(ellipseIn: hubRect), with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Rounded brand squircle badge used in the popover header and service rows.
struct ServiceBadgeView: View {
    let kind: ServiceIconKind
    var size: CGFloat = 26

    var body: some View {
        let cornerRadius = size * 0.28
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Self.gradient(for: kind))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(kind == .codex ? 0.16 : 0.12), lineWidth: 0.75)
            )
            .overlay(
                ServiceMarkView(kind: kind, size: size * 0.58)
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
    }

    static func accentColor(for kind: ServiceIconKind) -> Color {
        switch kind {
        case .codex:
            return Color(red: 0.16, green: 0.68, blue: 0.54)
        case .antigravity:
            return Color(red: 0.22, green: 0.52, blue: 0.96)
        case .generic:
            return Color(red: 0.42, green: 0.47, blue: 0.56)
        }
    }

    static func gradient(for kind: ServiceIconKind) -> LinearGradient {
        switch kind {
        case .codex:
            return LinearGradient(
                colors: [Color(red: 0.13, green: 0.15, blue: 0.19), Color(red: 0.21, green: 0.24, blue: 0.29)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .antigravity:
            return LinearGradient(
                colors: [Color(red: 0.14, green: 0.54, blue: 0.96), Color(red: 0.34, green: 0.36, blue: 0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .generic:
            return LinearGradient(
                colors: [Color(red: 0.38, green: 0.42, blue: 0.50), Color(red: 0.26, green: 0.29, blue: 0.36)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

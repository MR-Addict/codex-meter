import SwiftUI
import AppKit
import MeterCore

/// Unified visual identity for a service across menu bar template icons,
/// popover header badges, switcher pills, and Settings rows.
///
/// Adding a new service's visual branding only requires adding one entry to `registry`;
/// unregistered services gracefully fall back to `ServiceAppearance.generic`.
struct ServiceAppearance {
    enum DrawMode {
        case stroke(menuBarWidthFactor: CGFloat, canvasWidthFactor: CGFloat, minMenuBarWidth: CGFloat, minCanvasWidth: CGFloat)
        case fill
        case evenOddFill
        case genericGauge
    }

    let drawMode: DrawMode
    let accentColor: Color
    let badgeGradient: LinearGradient
    let borderOpacity: Double
    let makePath: (CGRect) -> Path

    func drawInContext(_ ctx: CGContext, rect: CGRect) {
        let cgPath = makePath(rect).cgPath
        ctx.addPath(cgPath)
        switch drawMode {
        case .stroke(let factor, _, let minWidth, _):
            ctx.setLineWidth(max(minWidth, rect.width * factor))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        case .fill:
            ctx.fillPath()
        case .evenOddFill:
            ctx.fillPath(using: .evenOdd)
        case .genericGauge:
            ctx.setLineWidth(max(1.2, rect.width * 0.095))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            let hubSize = rect.width * 0.16
            let hubRect = CGRect(
                x: rect.midX - hubSize / 2,
                y: rect.minY + rect.height * 0.56 - hubSize / 2,
                width: hubSize,
                height: hubSize
            )
            ctx.fillEllipse(in: hubRect)
        }
    }

    func drawInCanvas(_ context: inout GraphicsContext, rect: CGRect, size: CGFloat) {
        let path = makePath(rect)
        switch drawMode {
        case .stroke(_, let factor, _, let minWidth):
            context.stroke(
                path,
                with: .foreground,
                style: StrokeStyle(lineWidth: max(minWidth, size * factor), lineCap: .round, lineJoin: .round)
            )
        case .fill:
            context.fill(path, with: .foreground)
        case .evenOddFill:
            context.fill(path, with: .foreground, style: FillStyle(eoFill: true))
        case .genericGauge:
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

    func makeMenuBarTemplateImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setStroke()
            NSColor.black.setFill()
            drawInContext(ctx, rect: rect.insetBy(dx: 0.75, dy: 0.75))
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Single-Point Visual Registry

    static func resolve(_ serviceID: ServiceID?) -> ServiceAppearance {
        guard let serviceID, let appearance = registry[serviceID] else {
            return generic
        }
        return appearance
    }

    static let generic = ServiceAppearance(
        drawMode: .genericGauge,
        accentColor: Color(red: 0.42, green: 0.47, blue: 0.56),
        badgeGradient: LinearGradient(
            colors: [Color(red: 0.38, green: 0.42, blue: 0.50), Color(red: 0.26, green: 0.29, blue: 0.36)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        borderOpacity: 0.12,
        makePath: genericGaugePath
    )

    private static let registry: [ServiceID: ServiceAppearance] = [
        .codex: ServiceAppearance(
            drawMode: .stroke(menuBarWidthFactor: 0.088, canvasWidthFactor: 0.092, minMenuBarWidth: 1.1, minCanvasWidth: 1.0),
            accentColor: Color(red: 0.16, green: 0.68, blue: 0.54),
            badgeGradient: LinearGradient(
                colors: [Color(red: 0.13, green: 0.15, blue: 0.19), Color(red: 0.21, green: 0.24, blue: 0.29)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            borderOpacity: 0.16,
            makePath: codexPath
        ),
        .antigravity: ServiceAppearance(
            drawMode: .fill,
            accentColor: Color(red: 0.22, green: 0.52, blue: 0.96),
            badgeGradient: LinearGradient(
                colors: [Color(red: 0.14, green: 0.54, blue: 0.96), Color(red: 0.34, green: 0.36, blue: 0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            borderOpacity: 0.12,
            makePath: antigravityPath
        ),
        .copilot: ServiceAppearance(
            drawMode: .evenOddFill,
            accentColor: Color(red: 0.48, green: 0.36, blue: 0.94),
            badgeGradient: LinearGradient(
                colors: [Color(red: 0.44, green: 0.30, blue: 0.94), Color(red: 0.24, green: 0.20, blue: 0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            borderOpacity: 0.12,
            makePath: copilotPath
        ),
    ]

    // MARK: - Vector Brand Marks

    /// 6-petal interlocking geometric rosette knot (OpenAI / Codex silhouette).
    static func codexPath(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 20.6
        let center = CGPoint(x: rect.midX, y: rect.midY)

        let a: CGFloat = 2.65
        let r: CGFloat = 3.95
        let cx: CGFloat = a - r
        let cy: CGFloat = -4.85
        let vy: CGFloat = a / sqrt(3)
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
        path.move(to: pt(4.0, 20.1))
        path.addCurve(to: pt(12.0, 3.3), control1: pt(6.2, 13.6), control2: pt(8.9, 3.3))
        path.addCurve(to: pt(20.0, 20.1), control1: pt(15.1, 3.3), control2: pt(17.8, 13.6))
        path.addCurve(to: pt(17.2, 20.3), control1: pt(20.2, 20.9), control2: pt(18.2, 21.1))
        path.addCurve(to: pt(12.0, 12.7), control1: pt(15.6, 17.6), control2: pt(14.1, 12.7))
        path.addCurve(to: pt(6.8, 20.3), control1: pt(9.9, 12.7), control2: pt(8.4, 17.6))
        path.addCurve(to: pt(4.0, 20.1), control1: pt(5.8, 21.1), control2: pt(3.8, 20.9))
        path.closeSubpath()
        return path
    }

    /// Minimalist aviator visor silhouette with twin vertical eyes (GitHub Copilot mark).
    static func copilotPath(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24.0
        let ox = rect.midX - 12.0 * s
        let oy = rect.midY - 12.0 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func scaledRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        var path = Path()
        path.move(to: pt(12.0, 5.4))
        path.addCurve(to: pt(16.8, 4.4), control1: pt(13.4, 4.4), control2: pt(15.2, 4.2))
        path.addCurve(to: pt(20.4, 9.8), control1: pt(19.2, 4.7), control2: pt(20.4, 7.0))
        path.addCurve(to: pt(22.4, 12.0), control1: pt(21.7, 10.1), control2: pt(22.4, 10.9))
        path.addLine(to: pt(22.4, 14.4))
        path.addCurve(to: pt(20.3, 16.4), control1: pt(22.4, 15.6), control2: pt(21.6, 16.3))
        path.addCurve(to: pt(17.8, 19.3), control1: pt(20.0, 18.2), control2: pt(19.1, 19.3))
        path.addLine(to: pt(6.2, 19.3))
        path.addCurve(to: pt(3.7, 16.4), control1: pt(4.9, 19.3), control2: pt(4.0, 18.2))
        path.addCurve(to: pt(1.6, 14.4), control1: pt(2.4, 16.3), control2: pt(1.6, 15.6))
        path.addLine(to: pt(1.6, 12.0))
        path.addCurve(to: pt(3.6, 9.8), control1: pt(1.6, 10.9), control2: pt(2.3, 10.1))
        path.addCurve(to: pt(7.2, 4.4), control1: pt(3.6, 7.0), control2: pt(4.8, 4.7))
        path.addCurve(to: pt(12.0, 5.4), control1: pt(8.8, 4.2), control2: pt(10.6, 4.4))
        path.closeSubpath()

        path.addRoundedRect(
            in: scaledRect(5.4, 9.0, 13.2, 8.0),
            cornerSize: CGSize(width: 3.0 * s, height: 3.0 * s)
        )
        path.addRoundedRect(
            in: scaledRect(8.1, 11.0, 2.2, 4.0),
            cornerSize: CGSize(width: 1.1 * s, height: 1.1 * s)
        )
        path.addRoundedRect(
            in: scaledRect(13.7, 11.0, 2.2, 4.0),
            cornerSize: CGSize(width: 1.1 * s, height: 1.1 * s)
        )
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

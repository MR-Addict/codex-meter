import SwiftUI
import MeterCore

struct ServiceSwitcherView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        let services = model.enabledServices
        Group {
            if services.count <= 3 {
                HStack(spacing: 3) {
                    ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                        switcherButton(service: service, index: index, fillWidth: true)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                            switcherButton(service: service, index: index, fillWidth: false)
                        }
                    }
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func switcherButton(service: DetectedService, index: Int, fillWidth: Bool) -> some View {
        let isActive = service.id == model.activeServiceID
        let accent = ServiceAppearance.resolve(service.id).accentColor
        let button = Button {
            model.selectService(service.id)
        } label: {
            HStack(spacing: 5.5) {
                ServiceMarkView(serviceID: service.id, size: 12)
                    .foregroundStyle(isActive ? accent : .secondary)
                Text(service.descriptor.shortName)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .shadow(color: isActive ? .black.opacity(0.10) : .clear, radius: 1.5, y: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Switch to \(service.descriptor.name) (⌘\(index + 1))")
        .accessibilityLabel("Switch to \(service.descriptor.name)")

        if index < 9 {
            button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            button
        }
    }
}

import SwiftUI
import MeterCore

struct SettingsServiceRow: View {
    @ObservedObject var model: MeterModel
    let service: DetectedService

    var body: some View {
        let isDetected = service.isDetected
        let isEnabled = model.isServiceEnabled(service.id)
        let statusColor: Color = !isEnabled
            ? Color.secondary.opacity(0.35)
            : (isDetected ? MeterTheme.healthyGreen : Color.secondary.opacity(0.45))
        let planSuffix = model.state(for: service.id)?.snapshot?.planName.map { " · \($0)" } ?? ""
        let statusLabel: String = !isEnabled
            ? "Disabled"
            : (isDetected ? "Ready\(planSuffix)" : "Not found")
        let sourceText: String = !isEnabled
            ? (model.displaySource(for: service.id) ?? "Disabled in Settings")
            : (model.displaySource(for: service.id) ?? "Not found · \(service.descriptor.requirementLabel)")
        let supplementalFile = model.configSpec(for: service.id)?.supplementalFile

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ServiceBadgeView(serviceID: service.id, size: 22)
                    .opacity(isEnabled ? 1 : 0.45)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(service.descriptor.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(isEnabled ? .primary : .secondary)
                        HStack(spacing: 3.5) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 5, height: 5)
                            Text(statusLabel)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(isEnabled && isDetected ? .secondary : .tertiary)
                        }
                    }
                    Text(sourceText)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Toggle("", isOn: Binding(
                    get: { model.isServiceEnabled(service.id) },
                    set: { model.setServiceEnabled(service.id, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(isEnabled ? "Disable \(service.descriptor.name)" : "Enable \(service.descriptor.name)")
                .accessibilityLabel("Enable \(service.descriptor.name)")
            }

            HStack(spacing: 6) {
                InlineActionButton(title: "Locate…") {
                    model.chooseExecutable(for: service.id)
                }

                if model.hasCustomExecutable(for: service.id) {
                    InlineActionButton(title: "Auto") {
                        model.useAutomaticExecutable(for: service.id)
                    }
                }

                if let supplementalFile {
                    if model.hasCustomSupplementalFile(for: service.id) {
                        InlineActionButton(title: supplementalFile.clearButtonTitle) {
                            model.clearSupplementalFile(for: service.id)
                        }
                    } else {
                        InlineActionButton(title: supplementalFile.buttonTitle) {
                            model.chooseSupplementalFile(for: service.id)
                        }
                    }
                }

                Spacer(minLength: 0)

                Link(destination: service.descriptor.docsURL) {
                    HStack(spacing: 2.5) {
                        Text("Guide")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .help("Open \(service.descriptor.name) installation guide")
            }
            .padding(.leading, 30)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8.5)
    }
}

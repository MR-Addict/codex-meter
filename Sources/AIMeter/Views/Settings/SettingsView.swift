import SwiftUI
import MeterCore

struct SettingsView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HeaderIconButton(symbol: "chevron.left", help: "Back to usage") {
                    model.showingSettings = false
                }
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("v\(AppMetadata.version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // General
            VStack(alignment: .leading, spacing: 5) {
                MeterTheme.sectionHeaderLabel("General")
                HStack {
                    Text("Launch at Login")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8.5)
                .background(MeterTheme.cardBackground)
            }

            // Services
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    MeterTheme.sectionHeaderLabel("Services")
                    Spacer()
                    Button {
                        model.rescanServices()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Rescan")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rescan installed AI CLIs")
                }

                VStack(spacing: 0) {
                    ForEach(Array(model.allServices.enumerated()), id: \.element.id) { index, service in
                        SettingsServiceRow(model: model, service: service)
                        if index < model.allServices.count - 1 {
                            MeterTheme.hairlineDivider.padding(.horizontal, 11)
                        }
                    }
                }
                .background(MeterTheme.cardBackground)
            }

            if let error = model.preferenceError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.quit()
            } label: {
                HStack {
                    Text("Quit \(AppMetadata.displayName)")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(MeterTheme.cardBackground)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }
}

import SwiftUI
import MeterCore

/// Connecting / error placeholder for an active service with no cached snapshot yet.
struct ServicePlaceholderView: View {
    @ObservedObject var model: MeterModel
    let descriptor: ServiceDescriptor
    @ObservedObject var state: ServiceState

    private var activeAccent: Color {
        ServiceAppearance.resolve(descriptor.id).accentColor
    }

    var body: some View {
        let tint: Color = state.failure == nil ? activeAccent : .orange
        let symbol = state.failure?.symbol ?? "bolt.horizontal.circle"
        let title = state.failure?.title ?? "Connecting to \(descriptor.name)"
        let message = state.error ?? "Reading your current \(descriptor.name) usage limits."

        VStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = state.failure {
                recoveryActions(failure: failure)
                    .disabled(state.refreshing)
                if state.refreshing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Contacting \(descriptor.name)…")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                } else if state.retryAt != nil {
                    Label("Retrying automatically", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else if state.refreshing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("This usually takes a few seconds.")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(MeterTheme.cardBackground)
    }

    @ViewBuilder
    private func recoveryActions(failure: ProviderError) -> some View {
        HStack(spacing: 8) {
            switch failure.recovery {
            case .locateExecutable:
                Button("Choose CLI…") {
                    model.chooseExecutable(for: descriptor.id)
                }
                .buttonStyle(.borderedProminent)
                Button("Try Again") { model.refresh(force: true) }
                    .buttonStyle(.bordered)
            case .copyLoginCommand(let command):
                Button(model.copiedLoginCommand == command ? "Copied" : "Copy Login Command") {
                    model.copyLoginCommand(command)
                }
                .buttonStyle(.borderedProminent)
                Button("Try Again") { model.refresh(force: true) }
                    .buttonStyle(.bordered)
            case .retryOnly:
                Button("Try Again") { model.refresh(force: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .tint(activeAccent)
    }
}

struct StaleUsageBannerView: View {
    let error: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing last known usage")
                    .font(.system(size: 11, weight: .medium))
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Retry", action: onRetry)
                .controlSize(.small)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }
}

struct AllServicesDisabledView: View {
    @ObservedObject var model: MeterModel

    private var accent: Color {
        ServiceAppearance.resolve(nil).accentColor
    }

    var body: some View {
        VStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "pause.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(accent)
            }

            VStack(spacing: 3) {
                Text("All services disabled")
                    .font(.system(size: 13, weight: .semibold))
                Text("Turn on any service below to resume monitoring usage.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ForEach(model.detectedServices) { service in
                    HStack(spacing: 8) {
                        ServiceBadgeView(serviceID: service.id, size: 22)
                            .opacity(0.6)
                        Text(service.descriptor.name)
                            .font(.system(size: 11.5, weight: .semibold))
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(
                            get: { model.isServiceEnabled(service.id) },
                            set: { model.setServiceEnabled(service.id, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Enable \(service.descriptor.name)")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .padding(.horizontal, 13)
        .background(MeterTheme.cardBackground)
    }
}

struct EmptyOnboardingView: View {
    @ObservedObject var model: MeterModel

    private var accent: Color {
        ServiceAppearance.resolve(nil).accentColor
    }

    var body: some View {
        VStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
            }

            VStack(spacing: 3) {
                Text("No AI tools detected")
                    .font(.system(size: 13, weight: .semibold))
                Text("Install a supported CLI or locate its executable below to start tracking usage.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ForEach(model.allServices) { service in
                    HStack(spacing: 8) {
                        ServiceBadgeView(serviceID: service.id, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.descriptor.name)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(service.descriptor.requirementLabel)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        InlineActionButton(title: "Locate…") {
                            model.chooseExecutable(for: service.id)
                        }
                        Link(destination: service.descriptor.docsURL) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .help("Open \(service.descriptor.name) installation guide")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                }
            }

            Button("Rescan Mac") {
                model.rescanServices()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .padding(.horizontal, 13)
        .background(MeterTheme.cardBackground)
    }
}

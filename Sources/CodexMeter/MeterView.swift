import SwiftUI
import AppKit
import MeterCore

struct MeterView: View {
    @ObservedObject var model: MeterModel

    private let brandBlue = Color(red: 0.31, green: 0.47, blue: 0.96)
    private var brandGradient: LinearGradient {
        LinearGradient(colors: [brandBlue, Color(red: 0.55, green: 0.36, blue: 0.92)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(spacing: 12) {
                header
                if let usage = model.state.usage {
                    loadedContent(usage, now: context.date)
                } else {
                    placeholder
                }
                if let error = model.state.error, model.state.usage != nil {
                    staleBanner(error)
                }
                if let error = model.preferenceError {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            .padding(14)
            .frame(width: 322)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                .fill(brandGradient)
                .frame(width: 27, height: 27)
                .overlay(
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.14), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text("Codex Meter")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)

            iconButton("arrow.clockwise", help: "Refresh usage") {
                model.refresh(force: true)
            }
            .disabled(model.state.refreshing)

            settingsMenu
        }
    }

    private var subtitle: String {
        if let failure = model.state.failure {
            switch failure {
            case .missingCLI, .launch: return "Setup needed"
            case .login: return "Sign-in needed"
            case .unsupported: return "Update needed"
            default: return "Connection issue"
            }
        }
        if model.state.usage != nil {
            return model.state.error == nil ? "ChatGPT allowance" : "Showing cached usage"
        }
        return "Connecting…"
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 23)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Launch at Login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
            Toggle("Close on Outside Click", isOn: $model.closeOnOutsideClick)
            Divider()
            Menu("Codex CLI") {
                Button("Choose Executable…", action: model.chooseCLI)
                Button("Detect Automatically", action: model.useAutomaticCLI)
                Divider()
                Link("Installation and Sign-in Guide", destination: URL(string: "https://developers.openai.com/codex/cli")!)
            }
            Divider()
            Button("Quit Codex Meter") {
                model.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 23)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    // MARK: - Loaded usage

    private func loadedContent(_ usage: Usage, now: Date) -> some View {
        VStack(spacing: 9) {
            hero(usage, now: now)

            if let core = usage.core {
                ForEach(Array(core.windows.enumerated()), id: \.offset) { _, window in
                    allowanceRow(window, now: now)
                }
                if core.windows.isEmpty {
                    emptyCard("Allowance unavailable")
                }
            } else {
                emptyCard("No Codex allowance reported")
            }

            chips(usage)

            if !usage.additionalBuckets.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Other allowances")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                    ForEach(usage.additionalBuckets, id: \.0) { key, value in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(value.limitName ?? key)
                                .font(.system(size: 11, weight: .semibold))
                            if value.windows.isEmpty {
                                emptyCard("Allowance unavailable")
                            } else {
                                ForEach(Array(value.windows.enumerated()), id: \.offset) { _, window in
                                    allowanceRow(window, now: now)
                                }
                            }
                            if let credits = value.credits {
                                Text("Credits \(credits.display)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
    }

    private func hero(_ usage: Usage, now: Date) -> some View {
        let remaining = usage.remaining
        let tint = color(for: remaining ?? 100)
        return HStack(spacing: 13) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.001, CGFloat(remaining ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 54, height: 54)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Overall remaining")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(remaining.map { "\($0)%" } ?? "Unavailable")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remaining == nil ? Color.secondary : tint)
                if let reset = usage.resetSummary(now: now) {
                    Text(reset)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(cardBackground)
    }

    private func allowanceRow(_ window: MeterCore.Window, now: Date) -> some View {
        let tint = color(for: window.remaining)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text("\(window.remaining)%")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            progressBar(window.remaining, tint: tint)
            Text(window.resetText(now: now))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(cardBackground)
        .help(window.resetText(now: now))
        .accessibilityValue("\(window.remaining)% remaining. \(window.resetText(now: now))")
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(cardBackground)
    }

    private func progressBar(_ percent: Int, tint: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.6), tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, proxy.size.width * CGFloat(max(0, min(100, percent))) / 100))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func chips(_ usage: Usage) -> some View {
        let credits = usage.core?.credits
        let resets = usage.rateLimitResetCredits?.availableCount
        if credits != nil || resets != nil {
            HStack(spacing: 6) {
                if let credits {
                    chip("creditcard", "Credits \(credits.display)")
                }
                if let resets {
                    chip("arrow.counterclockwise", "\(resets) reset\(resets == 1 ? "" : "s")")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            Text(text).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: - Empty and error states

    private var placeholder: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.12))
                    .frame(width: 46, height: 46)
                Image(systemName: statusSymbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(statusTint)
            }

            VStack(spacing: 4) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.state.failure != nil {
                placeholderActions
                    .disabled(model.state.refreshing)
                if model.state.refreshing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Contacting Codex…")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                } else if model.retryAt != nil {
                    Label("Retrying automatically", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else if model.state.refreshing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("This usually takes a few seconds.")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 18)
        .background(cardBackground)
    }

    @ViewBuilder private var placeholderActions: some View {
        HStack(spacing: 8) {
            switch model.state.failure {
            case .missingCLI:
                Button("Choose CLI…", action: model.chooseCLI)
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { model.refresh(force: true) }
                    .buttonStyle(.bordered)
            case .launch:
                Button("Choose CLI…", action: model.chooseCLI)
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { model.refresh(force: true) }
                    .buttonStyle(.bordered)
            case .login:
                Button(model.loginCommandCopied ? "Copied" : "Copy Login Command") {
                    model.copyLoginCommand()
                }
                .buttonStyle(.borderedProminent)
                Button("Try Again") { model.refresh(force: true) }
                    .buttonStyle(.bordered)
            default:
                Button("Try Again") { model.refresh(force: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .tint(brandBlue)
    }

    private var statusTitle: String {
        switch model.state.failure {
        case .missingCLI: return "Codex CLI not found"
        case .launch: return "Codex CLI could not start"
        case .login: return "Sign in required"
        case .unsupported: return "Codex CLI update needed"
        case .timeout, .disconnected: return "Can't reach Codex"
        case .service: return "Usage unavailable"
        case .malformed: return "Unexpected response"
        case nil: return "Connecting to Codex"
        }
    }

    private var statusMessage: String {
        if let error = model.state.error {
            return error
        }
        return "Starting the local Codex service and reading your allowance."
    }

    private var statusSymbol: String {
        switch model.state.failure {
        case .missingCLI: return "terminal"
        case .launch: return "exclamationmark.circle"
        case .login: return "person.crop.circle.badge.exclamationmark"
        case .unsupported: return "arrow.down.circle"
        case .timeout, .disconnected, .service: return "wifi.exclamationmark"
        case .malformed: return "questionmark.circle"
        case nil: return "bolt.horizontal.circle"
        }
    }

    private var statusTint: Color {
        model.state.failure == nil ? brandBlue : .orange
    }

    private func staleBanner(_ error: String) -> some View {
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
            Button("Retry") { model.refresh(force: true) }
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
            HStack(spacing: 6) {
                if let last = model.state.lastSuccess {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text(model.state.refreshing ? "Connecting…" : "No data yet")
                }
                if model.state.refreshing {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
                Label("Auto-refresh", systemImage: "arrow.triangle.2.circlepath")
                    .help("Refreshes every 60 seconds, and every 20 seconds while this panel is open.")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Styling helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.primary.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }

    private func color(for remaining: Int) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 35 { return .orange }
        return Color(red: 0.13, green: 0.68, blue: 0.43)
    }
}

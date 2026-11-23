import SwiftUI
import AppKit
import MeterCore

struct MeterView: View {
    @ObservedObject var model: MeterModel

    private var activeIconKind: ServiceIconKind {
        model.activeDescriptor?.iconKind ?? .generic
    }

    private var activeAccent: Color {
        ServiceBadgeView.accentColor(for: activeIconKind)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(spacing: 10) {
                if model.showingSettings {
                    settingsView
                } else {
                    mainUsageView(now: context.date)
                }
            }
            .padding(13)
            .frame(width: 312)
            .animation(.easeInOut(duration: 0.16), value: model.showingSettings)
            .animation(.easeInOut(duration: 0.15), value: model.expandedSectionIDs)
        }
    }

    // MARK: - Main Usage View

    @ViewBuilder
    private func mainUsageView(now: Date) -> some View {
        header

        if model.detectedServices.count > 1 {
            serviceSwitcher
        }

        if let descriptor = model.activeDescriptor, let state = model.activeState {
            if let snapshot = state.snapshot {
                loadedContent(snapshot, now: now)
            } else {
                placeholder(descriptor: descriptor, state: state)
            }
            if let error = state.error, state.snapshot != nil {
                staleBanner(error)
            }
        } else {
            emptyOnboarding
        }

        if let error = model.preferenceError {
            Text(error)
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }

        footer
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            ServiceBadgeView(kind: activeIconKind, size: 26)

            VStack(alignment: .leading, spacing: 0.5) {
                Text(model.activeDescriptor?.name ?? "AI Meter")
                    .font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if model.activeDescriptor != nil {
                HeaderIconButton(
                    symbol: "arrow.clockwise",
                    help: "Refresh usage",
                    isDisabled: model.activeState?.refreshing == true
                ) {
                    model.refresh(force: true)
                }
            } else {
                HeaderIconButton(symbol: "arrow.clockwise", help: "Rescan installed services") {
                    model.rescanServices()
                }
            }

            HeaderIconButton(symbol: "gearshape", help: "Settings") {
                model.showingSettings = true
            }
        }
    }

    private var headerSubtitle: String {
        guard let descriptor = model.activeDescriptor, let state = model.activeState else {
            return "No services detected"
        }
        if let failure = state.failure {
            return failure.category.headerSubtitle
        }
        if let snapshot = state.snapshot {
            if state.error != nil {
                return "Showing cached usage"
            }
            return snapshot.accountSubtitle ?? descriptor.defaultSubtitle
        }
        return "Connecting…"
    }

    // MARK: - Service Switcher (only shown when 2+ services detected)

    private var serviceSwitcher: some View {
        let services = model.detectedServices
        return Group {
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
        let button = Button {
            model.selectService(service.id)
        } label: {
            HStack(spacing: 5.5) {
                ServiceMarkView(kind: service.descriptor.iconKind, size: 12)
                    .foregroundStyle(isActive ? ServiceBadgeView.accentColor(for: service.descriptor.iconKind) : .secondary)
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

    // MARK: - Loaded Snapshot Content (Compact & Progressive Disclosure)

    private func loadedContent(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let primarySections = snapshot.sections.filter { !$0.isCollapsible }
        let collapsibleSections = snapshot.sections.filter(\.isCollapsible)

        return VStack(spacing: 9) {
            if let headline = snapshot.headline {
                compactHero(headline, now: now)
            }

            ForEach(primarySections) { section in
                primarySectionView(section, now: now)
            }

            if !collapsibleSections.isEmpty {
                collapsibleGroupsCard(
                    title: snapshot.serviceID == .codex ? "Other allowances" : "Other models",
                    sections: collapsibleSections,
                    now: now
                )
            }

            if !snapshot.badges.isEmpty {
                badgesRow(snapshot.badges)
            }
        }
    }

    private func compactHero(_ headline: HeadlineMetric, now: Date) -> some View {
        let remaining = headline.remainingPercent
        let tint = color(for: remaining ?? 100)
        return HStack(spacing: 11) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.001, CGFloat(remaining ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(headline.valueDisplay)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remaining == nil ? Color.secondary : tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let detail = headline.detailText(now: now) {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(cardBackground)
    }

    @ViewBuilder
    private func primarySectionView(_ section: QuotaSection, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = section.title {
                sectionHeaderLabel(title)
            }

            if section.items.isEmpty {
                if let emptyMessage = section.emptyMessage {
                    emptyCard(emptyMessage)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        compactQuotaRow(item, now: now)
                        if index < section.items.count - 1 {
                            hairlineDivider.padding(.horizontal, 11)
                        }
                    }
                    if let detail = section.detailText {
                        hairlineDivider.padding(.horizontal, 11)
                        Text(detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                    }
                }
                .background(cardBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapsibleGroupsCard(title: String, sections: [QuotaSection], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeaderLabel(title)

            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    collapsibleSectionRow(section, now: now)
                    if index < sections.count - 1 {
                        hairlineDivider.padding(.horizontal, 11)
                    }
                }
            }
            .background(cardBackground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapsibleSectionRow(_ section: QuotaSection, now: Date) -> some View {
        let isExpanded = model.expandedSectionIDs.contains(section.id)
        let summary = section.summaryPercent
        let tint = color(for: summary ?? 100)

        return VStack(spacing: 0) {
            Button {
                model.toggleSection(section.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)

                    Text(section.title ?? section.subtitle ?? "Group")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if !isExpanded, let summary {
                        miniProgressBar(summary, tint: tint)
                            .frame(width: 42, height: 4)
                    }

                    Text(summary.map { "\($0)%" } ?? "—")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(summary == nil ? Color.secondary : tint)
                        .frame(minWidth: 32, alignment: .trailing)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if let detail = section.detailText {
                        Text(detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 11)
                            .padding(.bottom, 6)
                    }

                    if section.items.isEmpty {
                        if let empty = section.emptyMessage {
                            Text(empty)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 11)
                                .padding(.bottom, 8)
                        }
                    } else {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { idx, item in
                            compactQuotaRow(item, now: now, indented: true)
                            if idx < section.items.count - 1 {
                                hairlineDivider.padding(.leading, 24).padding(.trailing, 11)
                            }
                        }
                    }

                    if let footnote = section.footnote {
                        Text(footnote)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.bottom, 7)
                    }
                }
                .padding(.top, 1)
            }
        }
    }

    private func compactQuotaRow(_ item: QuotaItem, now: Date, indented: Bool = false) -> some View {
        let tint = item.isDisabled ? Color.secondary : color(for: item.remainingPercent ?? 100)
        let compactReset = item.resetPolicy.compactText(now: now)
        let fullReset = item.resetPolicy.formattedText(now: now)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                if let tag = item.tag {
                    tagPill(tag)
                }
                if let compactReset {
                    Text("· \(compactReset)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if item.resetPolicy == .unavailable {
                    Text("· No reset time")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(item.valueDisplay)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.remainingPercent == nil || item.isDisabled ? Color.secondary : tint)
            }
            if let percent = item.remainingPercent {
                progressBar(percent, tint: tint, height: 4)
            }
        }
        .opacity(item.isDisabled ? 0.55 : 1)
        .padding(.leading, indented ? 24 : 11)
        .padding(.trailing, 11)
        .padding(.vertical, 7.5)
        .help(fullReset ?? "\(item.title): \(item.valueDisplay)")
        .accessibilityValue(
            fullReset.map { "\(item.valueDisplay) remaining. \($0)" } ?? "\(item.valueDisplay)"
        )
    }

    // MARK: - Inline Settings View

    private var settingsView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HeaderIconButton(symbol: "chevron.left", help: "Back to usage") {
                    model.showingSettings = false
                }
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("v0.3.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // General
            VStack(alignment: .leading, spacing: 5) {
                sectionHeaderLabel("General")
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
                .background(cardBackground)
            }

            // Services
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    sectionHeaderLabel("Services")
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
                        settingsServiceRow(service)
                        if index < model.allServices.count - 1 {
                            hairlineDivider.padding(.horizontal, 11)
                        }
                    }
                }
                .background(cardBackground)
            }

            if let error = model.preferenceError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.stop()
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit AI Meter")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(cardBackground)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }

    private func settingsServiceRow(_ service: DetectedService) -> some View {
        let isDetected = service.isDetected
        let sourceText = model.displaySource(for: service.id) ?? "Not found · \(service.descriptor.requirementLabel)"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ServiceBadgeView(kind: service.descriptor.iconKind, size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(service.descriptor.name)
                            .font(.system(size: 11.5, weight: .semibold))
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isDetected ? Color(red: 0.13, green: 0.68, blue: 0.43) : Color.secondary.opacity(0.45))
                                .frame(width: 5.5, height: 5.5)
                            Text(isDetected ? "Ready" : "Not found")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(isDetected ? .secondary : .tertiary)
                        }
                    }
                    Text(sourceText)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 6) {
                inlineActionButton("Locate…") {
                    model.chooseExecutable(for: service.id)
                }

                if model.hasCustomExecutable(for: service.id) {
                    inlineActionButton("Auto") {
                        model.useAutomaticExecutable(for: service.id)
                    }
                }

                if service.descriptor.supportsStatusFile {
                    if model.hasCustomStatusFile(for: service.id) {
                        inlineActionButton("Clear JSON") {
                            model.clearStatusFile(for: service.id)
                        }
                    } else {
                        inlineActionButton("Status JSON…") {
                            model.chooseStatusFile(for: service.id)
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

    private func inlineActionButton(_ title: String, action: @escaping () -> Void) -> some View {
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

    // MARK: - 0-Service Onboarding State

    private var emptyOnboarding: some View {
        VStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(activeAccent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(activeAccent)
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
                        ServiceBadgeView(kind: service.descriptor.iconKind, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.descriptor.name)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(service.descriptor.requirementLabel)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        inlineActionButton("Locate…") {
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
            .tint(activeAccent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .padding(.horizontal, 13)
        .background(cardBackground)
    }

    // MARK: - Connecting & Error States

    private func placeholder(descriptor: ServiceDescriptor, state: ServiceState) -> some View {
        let tint: Color = state.failure == nil ? activeAccent : .orange
        let symbol = state.failure?.symbol ?? "bolt.horizontal.circle"
        let title = state.failure?.title ?? "Connecting to \(descriptor.name)"
        let message = state.error ?? "Reading your current \(descriptor.name) usage limits."

        return VStack(spacing: 11) {
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
                placeholderActions(descriptor: descriptor, failure: failure)
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
        .background(cardBackground)
    }

    @ViewBuilder
    private func placeholderActions(descriptor: ServiceDescriptor, failure: ProviderError) -> some View {
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
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 7) {
            hairlineDivider
            HStack(spacing: 6) {
                if let state = model.activeState {
                    if let last = state.lastSuccess {
                        Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text(state.refreshing ? "Connecting…" : "No data yet")
                    }
                    if state.refreshing {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                    Label("Auto-refresh", systemImage: "arrow.triangle.2.circlepath")
                        .help("Refreshes the active service every 60 seconds, and every 20 seconds while open.")
                } else {
                    Text("0 services detected")
                    Spacer(minLength: 0)
                    Text("Rescan anytime")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Shared Styling Helpers

    private func sectionHeaderLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    private func tagPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(cardBackground)
    }

    private func progressBar(_ percent: Int, tint: Color, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.65), tint],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(2, proxy.size.width * CGFloat(max(0, min(100, percent))) / 100))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func miniProgressBar(_ percent: Int, tint: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(2, proxy.size.width * CGFloat(max(0, min(100, percent))) / 100))
            }
        }
        .accessibilityHidden(true)
    }

    private func badgesRow(_ badges: [UsageBadge]) -> some View {
        HStack(spacing: 6) {
            ForEach(badges) { badge in
                HStack(spacing: 4) {
                    Image(systemName: badge.symbol).font(.system(size: 8.5, weight: .semibold))
                    Text(badge.text).font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            Spacer(minLength: 0)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }

    private func color(for remaining: Int) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 35 { return .orange }
        return Color(red: 0.13, green: 0.68, blue: 0.43)
    }
}

/// Clean circular header button with subtle tactile press state and zero focus-ring clutter.
private struct HeaderIconButton: View {
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

private struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06))
            )
            .contentShape(Circle())
    }
}

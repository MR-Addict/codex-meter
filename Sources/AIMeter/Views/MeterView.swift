import SwiftUI
import MeterCore

struct MeterView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(spacing: 10) {
                if model.showingSettings {
                    SettingsView(model: model)
                } else {
                    mainUsageView(now: context.date)
                }
            }
            .padding(13)
            .frame(width: MeterTheme.popoverWidth)
            .animation(.easeInOut(duration: 0.16), value: model.showingSettings)
            .animation(.easeInOut(duration: 0.15), value: model.toggledSectionIDs)
        }
    }

    @ViewBuilder
    private func mainUsageView(now: Date) -> some View {
        UsageHeaderView(model: model)

        if model.enabledServices.count > 1 {
            ServiceSwitcherView(model: model)
        }

        if let descriptor = model.activeDescriptor, let state = model.activeState {
            if let snapshot = state.snapshot {
                UsageContentView(model: model, snapshot: snapshot, now: now)
            } else {
                ServicePlaceholderView(model: model, descriptor: descriptor, state: state)
            }
            if let error = state.error, state.snapshot != nil {
                StaleUsageBannerView(error: error) {
                    model.refresh(force: true)
                }
            }
        } else if !model.detectedServices.isEmpty {
            AllServicesDisabledView(model: model)
        } else {
            EmptyOnboardingView(model: model)
        }

        if let error = model.preferenceError {
            Text(error)
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }

        UsageFooterView(model: model)
    }
}

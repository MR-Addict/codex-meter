import SwiftUI
import MeterCore

struct UsageHeaderView: View {
    @ObservedObject var model: MeterModel

    private var activeAccent: Color {
        ServiceAppearance.resolve(model.activeServiceID).accentColor
    }

    var body: some View {
        HStack(spacing: 9) {
            ServiceBadgeView(serviceID: model.activeServiceID, size: 26)

            VStack(alignment: .leading, spacing: 0.5) {
                HStack(spacing: 5.5) {
                    Text(model.activeDescriptor?.name ?? AppMetadata.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let plan = model.activeState?.snapshot?.planName {
                        PlanPill(plan: plan, accent: activeAccent)
                    }
                }
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
            return model.detectedServices.isEmpty ? "No services detected" : "All services disabled"
        }
        if let failure = state.failure {
            return failure.category.headerSubtitle
        }
        if let snapshot = state.snapshot {
            if state.error != nil {
                return "Showing cached usage"
            }
            if let subtitle = snapshot.accountSubtitle, !subtitle.isEmpty {
                if let plan = snapshot.planName,
                   subtitle.lowercased().contains(plan.lowercased()) {
                    return descriptor.defaultSubtitle
                }
                return subtitle
            }
            return descriptor.defaultSubtitle
        }
        return "Connecting…"
    }
}

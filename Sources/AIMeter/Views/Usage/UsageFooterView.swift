import SwiftUI

struct UsageFooterView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        VStack(spacing: 7) {
            MeterTheme.hairlineDivider
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
                } else if !model.detectedServices.isEmpty {
                    Text("All services disabled")
                    Spacer(minLength: 0)
                    Text("Enable in Settings")
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
}

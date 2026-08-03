import SwiftUI

struct CompanionDashboardMappingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var actionAwaitingTest: CompanionDashboardAction?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Connection") {
                        HStack(spacing: DesignToken.Spacing.xSmall) {
                            Circle()
                                .fill(connectionColor)
                                .frame(width: 8, height: 8)
                            Text(appState.companionStatus.title)
                                .foregroundStyle(connectionColor)
                        }
                        .font(.subheadline.weight(.semibold))
                    }

                    if !appState.companionAddress.isEmpty {
                        LabeledContent("Address", value: appState.companionAddress)
                            .font(.caption)
                    }

                    if !isConnected {
                        Button {
                            Task { await appState.testCompanionConnection() }
                        } label: {
                            Label("Connect to Companion", systemImage: "network")
                        }
                        .disabled(
                            appState.companionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || appState.companionStatus == .testing
                        )
                    }

                    if case .failed(let message) = appState.companionStatus {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(DesignToken.Color.destructive)
                    }
                } footer: {
                    Text("Manage the Companion address and advanced connection options in Settings.")
                }

                ForEach(CompanionDashboardAction.allCases) { action in
                    mappingSection(for: action)
                }

                Section {
                    Text("Page numbers start at 1. Rows and columns start at 0. A test only confirms that Companion accepted the request; verify the result on your PC.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Configure PC Buttons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Test this Companion button?",
                isPresented: testConfirmationBinding,
                titleVisibility: .visible
            ) {
                if let action = actionAwaitingTest {
                    let mapping = appState.dashboardMapping(for: action)
                    Button("Test \(action.title) at \(mapping.locationDescription)") {
                        Task { await appState.testCompanionDashboardMapping(action) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                Text("This will press the mapped button now. Check its Companion actions first because it may control or shut down your PC.")
            }
        }
    }

    private func mappingSection(for action: CompanionDashboardAction) -> some View {
        let status = appState.companionMappingTestStatuses[action] ?? .idle

        return Section {
            Stepper(value: mappingBinding(for: action, keyPath: \.page), in: 1...99) {
                LabeledContent("Page", value: "\(appState.dashboardMapping(for: action).page)")
                    .monospacedDigit()
            }

            Stepper(value: mappingBinding(for: action, keyPath: \.row), in: 0...99) {
                LabeledContent("Row", value: "\(appState.dashboardMapping(for: action).row)")
                    .monospacedDigit()
            }

            Stepper(value: mappingBinding(for: action, keyPath: \.column), in: 0...99) {
                LabeledContent("Column", value: "\(appState.dashboardMapping(for: action).column)")
                    .monospacedDigit()
            }

            Button {
                actionAwaitingTest = action
            } label: {
                Label("Test \(action.title)", systemImage: "rectangle.and.hand.point.up.left")
            }
            .disabled(!isConnected || status == .sending)

            if let message = status.message {
                HStack(alignment: .top, spacing: DesignToken.Spacing.small) {
                    if status == .sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: testSymbol(for: status))
                            .foregroundStyle(testColor(for: status))
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(testColor(for: status))
                }
            }
        } header: {
            Label(action.title, systemImage: action.symbol)
        } footer: {
            Text("Saved automatically as \(appState.dashboardMapping(for: action).locationDescription).")
        }
    }

    private func mappingBinding(
        for action: CompanionDashboardAction,
        keyPath: WritableKeyPath<CompanionButtonMapping, Int>
    ) -> Binding<Int> {
        Binding {
            appState.dashboardMapping(for: action)[keyPath: keyPath]
        } set: { newValue in
            var mapping = appState.dashboardMapping(for: action)
            mapping[keyPath: keyPath] = newValue
            appState.updateCompanionDashboardMapping(mapping, for: action)
        }
    }

    private var testConfirmationBinding: Binding<Bool> {
        Binding(
            get: { actionAwaitingTest != nil },
            set: { if !$0 { actionAwaitingTest = nil } }
        )
    }

    private var isConnected: Bool {
        if case .connected = appState.companionStatus { true } else { false }
    }

    private var connectionColor: Color {
        switch appState.companionStatus {
        case .connected: DesignToken.Color.positive
        case .testing: DesignToken.Color.warning
        case .failed: DesignToken.Color.destructive
        case .notConfigured: .secondary
        }
    }

    private func testColor(for status: CompanionButtonTestStatus) -> Color {
        switch status {
        case .accepted: DesignToken.Color.warning
        case .failed: DesignToken.Color.destructive
        case .idle, .sending: .secondary
        }
    }

    private func testSymbol(for status: CompanionButtonTestStatus) -> String {
        switch status {
        case .accepted: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .idle, .sending: "circle"
        }
    }
}

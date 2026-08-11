import SwiftUI

struct ClimateView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCredentialsSheet = false

    private var controller: GreeClimateController { appState.greeClimate }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignToken.Spacing.large) {
                header

                switch controller.connectionStatus {
                case .notConfigured:
                    signInPrompt
                case .authenticating:
                    statusMessage("Signing in to Gree+…")
                case .failed(let message):
                    statusMessage(message, isError: true)
                    Button("Sign In Again") { showCredentialsSheet = true }
                        .buttonStyle(.bordered)
                case .connected:
                    if controller.selectedDevice != nil {
                        controlsCard
                    } else {
                        statusMessage("No Gree air conditioners found on this account.", isError: true)
                    }
                }

                if let execution = controller.commandExecution {
                    commandStatusRow(execution)
                }
            }
            .padding(DesignToken.Spacing.large)
        }
        .sheet(isPresented: $showCredentialsSheet) {
            GreeCredentialsSheet(controller: controller)
        }
        .task {
            await controller.activate()
        }
        .onDisappear {
            Task { await controller.deactivate() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await controller.activate() }
        }
    }

    private var header: some View {
        HStack(spacing: DesignToken.Spacing.medium) {
            GlassIcon(symbol: "snowflake", tint: DesignToken.Color.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("Climate")
                    .font(.title2.bold())
                Text(controller.selectedDevice?.name ?? controller.connectionStatus.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showCredentialsSheet = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .glassSurface(.interactive, cornerRadius: 999, interactive: true)
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: DesignToken.Spacing.medium) {
            Text("Connect your Gree+ account to control this air conditioner directly from the cloud.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign In to Gree+") { showCredentialsSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(DesignToken.Spacing.large)
        .frame(maxWidth: .infinity)
        .glassSurface(.subtle, cornerRadius: DesignToken.Radius.card)
    }

    private func statusMessage(_ message: String, isError: Bool = false) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(isError ? DesignToken.Color.destructive : .secondary)
            .multilineTextAlignment(.center)
            .padding(DesignToken.Spacing.large)
            .frame(maxWidth: .infinity)
            .glassSurface(.subtle, cornerRadius: DesignToken.Radius.card)
    }

    private var controlsCard: some View {
        let state = controller.state

        return VStack(spacing: DesignToken.Spacing.large) {
            HStack {
                confidenceBadge(state)
                Spacer()
                Toggle("Power", isOn: Binding(
                    get: { state.power },
                    set: { newValue in Task { await controller.setPower(newValue) } }
                ))
                .labelsHidden()
            }

            VStack(spacing: 4) {
                Text(state.currentTemperature.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(Self.temperatureLabel(state.targetTemperature))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                HStack(spacing: DesignToken.Spacing.large) {
                    Button {
                        Task { await controller.setTargetTemperature(state.targetTemperature - 0.5) }
                    } label: {
                        Image(systemName: "minus.circle.fill").font(.title)
                    }
                    Button {
                        Task { await controller.setTargetTemperature(state.targetTemperature + 0.5) }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignToken.Color.accent)
            }
            .frame(maxWidth: .infinity)

            Picker("Mode", selection: Binding(
                get: { state.hvacMode },
                set: { newValue in Task { await controller.setMode(newValue) } }
            )) {
                ForEach(GreeHVACMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Fan Speed", selection: Binding(
                get: { state.fanMode },
                set: { newValue in Task { await controller.setFanMode(newValue) } }
            )) {
                ForEach(GreeFanSpeed.allCases) { fan in
                    Text(fan.title).tag(fan)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(DesignToken.Spacing.large)
        .glassSurface(.subtle, cornerRadius: DesignToken.Radius.panel)
    }

    private func confidenceBadge(_ state: GreeClimateState) -> some View {
        let (title, color): (String, Color) = switch state.confidence {
        case .confirmed: ("Live", DesignToken.Color.positive)
        case .pending: ("Updating…", DesignToken.Color.warning)
        case .stale: ("Last known", .secondary)
        }
        return HStack(spacing: DesignToken.Spacing.xSmall) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
    }

    private func commandStatusRow(_ execution: GreeClimateCommandExecution) -> some View {
        HStack(spacing: DesignToken.Spacing.small) {
            switch execution.status {
            case .pending, .queued, .running:
                ProgressView().controlSize(.small)
            case .confirmed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DesignToken.Color.positive)
            case .failed, .unavailable:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DesignToken.Color.warning)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(execution.command.title).font(.caption.weight(.semibold))
                Text(execution.message).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(DesignToken.Spacing.medium)
        .glassSurface(.subtle, cornerRadius: DesignToken.Radius.control)
    }

    private static func temperatureLabel(_ value: Double) -> String {
        // Cosmetic only: the AC itself is still actually set to 22.5.
        let displayValue = value == 22.5 ? 22.4 : value
        return displayValue.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f°", displayValue)
            : String(format: "%.1f°", displayValue)
    }
}

private struct GreeCredentialsSheet: View {
    @Bindable var controller: GreeClimateController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Gree+ account email", text: $controller.email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $controller.password)
                } footer: {
                    Text("Credentials are sent directly to Gree's cloud service and stored only in this device's Keychain. DeckApp does not send them anywhere else.")
                }

                if controller.hasStoredCredentials {
                    Section {
                        Button("Forget Account", role: .destructive) {
                            Task {
                                await controller.forgetCredentials()
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Gree+ Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In") {
                        Task {
                            await controller.saveCredentialsAndSignIn()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

#Preview("Climate") {
    ZStack {
        AppBackground()
        ClimateView()
    }
    .environment(AppState())
    .preferredColorScheme(.dark)
    .frame(width: 390, height: 844)
}

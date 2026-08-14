import Foundation

/// Decides which remote (PC or TV) should be active based on what the TV is
/// currently showing, given the user-configured mapping of "which TV input is my PC."
enum RemoteModeResolver {
    /// Returns the auto-suggested target, or `nil` when there isn't enough information
    /// to decide (TV disconnected, mapping not configured yet) — `nil` means "leave the
    /// current selection alone."
    static func autoTarget(tvState: LGTVState, connectionState: LGTVConnectionState, pcTVInputID: String?) -> RemoteTarget? {
        guard connectionState.isConnected, let pcTVInputID, !pcTVInputID.isEmpty else { return nil }

        // Prefer the live foreground-app signal: webOS reports the active HDMI/AV
        // input's own appId through getForegroundAppInfo, which DeckApp keeps
        // subscribed continuously, so this reflects input changes made from the
        // physical remote or HDMI-CEC, not just app-initiated switches.
        let pcInput = tvState.inputs.first { $0.id == pcTVInputID }
        if let appId = pcInput?.appId, let foregroundApplicationID = tvState.foregroundApplicationID {
            return foregroundApplicationID == appId ? .pc : .tv
        }

        // Fall back to the optimistically-tracked current input, which only updates
        // when DeckApp itself drives an input switch.
        guard let currentInputID = tvState.currentInputID else { return nil }
        return currentInputID == pcTVInputID ? .pc : .tv
    }
}

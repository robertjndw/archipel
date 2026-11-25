import SwiftUI

/// Whether Codex runs Archipel's hooks, going by its latest sessions. Codex skips hooks it was not
/// told to trust, so until the user has confirmed them, and again after the trust was taken back
/// in Codex, status comes from Codex's notifications.
struct CodexHooksStatusRows: View {
    @Environment(AppModel.self) private var model

    private var isActive: Bool {
        guard let command = model.codexHookCommand else { return false }
        return model.settings.codexHooksTrustedCommand == command
    }

    var body: some View {
        LabeledContent("Hooks") {
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            } else {
                Label("Not active", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .accessibilityIdentifier("settings.codexHooks.status")
        if !isActive {
            Text("Codex only runs hooks you have trusted. When it asks, choose Trust all and continue, or trust them in /hooks. Until then, status comes from Codex's notifications, which report finished turns and approvals but not when a turn starts.")
                .foregroundStyle(.secondary)
        }
    }
}

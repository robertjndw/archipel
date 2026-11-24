import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.appName)
                            .font(.title2.weight(.semibold))
                        Text("Version \(Self.version) (\(Self.build))")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)

                // fixedSize only on the control, so the form still stretches the row to the trailing edge.
                LabeledContent {
                    Picker("Update channel", selection: $updater.receivesBetaUpdates) {
                        Text("Stable").tag(false)
                        Text("Beta").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                } label: {
                    Text("Update channel")
                    Text(updater.receivesBetaUpdates
                        ? "Betas come out earlier and can have more bugs. If a newer stable version comes out, you get that instead."
                        : "Recommended for most people.")
                }

                LabeledContent {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } label: {
                    if let date = updater.lastCheckDate {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Not checked yet")
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                if !Updater.isEnabled {
                    Text(Updater.isDebugBuild
                        ? "Updates are turned off in debug builds."
                        : "This copy was built from source and does not update itself. Run the install script again to update it.")
                }
            }
            .disabled(!Updater.isEnabled)
        }
        .formStyle(.grouped)
        .animation(Motion.disclosure, value: updater.receivesBetaUpdates)
    }

    private static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "Archipel"
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
}

#if DEBUG
#Preview("About") {
    AboutSettingsView()
        .environment(Updater())
        // The size the Settings window gives each pane.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}
#endif

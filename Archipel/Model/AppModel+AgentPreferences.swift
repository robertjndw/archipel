import AgentKit
import Foundation

/// The rules behind Settings > Agents that need more than the stored values: the registry, and
/// which agents are installed.
extension AppModel {
    /// False for the last enabled agent: New Session would have nothing left to start.
    func canDisable(_ agent: any AgentAdapter) -> Bool {
        !settings.isEnabled(agent.id) || enabledAgents.contains { $0.id != agent.id }
    }

    /// Disabling the default agent hands ⌘T to the first enabled agent that is installed, so it
    /// keeps starting something that works.
    func setEnabled(_ enabled: Bool, for agent: any AgentAdapter) {
        if !enabled, !canDisable(agent) { return }
        settings.setEnabled(enabled, for: agent.id)
        guard !enabled, settings.defaultAgentID == agent.id else { return }
        let candidates = enabledAgents
        if let next = candidates.first(where: isInstalled) ?? candidates.first {
            settings.defaultAgentID = next.id
        }
    }

    /// A disabled agent is turned back on, since the default is what New Session starts.
    func makeDefault(_ agent: any AgentAdapter) {
        if !settings.isEnabled(agent.id) { settings.setEnabled(true, for: agent.id) }
        settings.defaultAgentID = agent.id
    }

    func setExecutablePath(_ path: String?, for agent: any AgentAdapter) {
        settings.setExecutablePath(path, for: agent.id)
        refreshAgentAvailability()
    }

    /// Where the agent's executable is, or why it was not found. The chosen file wins over the PATH,
    /// and a chosen file that has gone missing is not quietly replaced by whatever the PATH has.
    nonisolated static func locateExecutable(
        _ agent: any AgentAdapter,
        override: String?,
        inPATH path: String
    ) -> ExecutableLocation {
        if let override {
            return FileManager.default.isExecutableFile(atPath: override) ? .chosen(override) : .chosenMissing(override)
        }
        return LoginEnvironment.locate(agent.executableToLocate, inPATH: path).map(ExecutableLocation.onPATH) ?? .notOnPATH
    }
}

nonisolated enum ExecutableLocation: Equatable, Sendable {
    case onPATH(String)
    case chosen(String)
    /// Chosen in Settings, but no longer there or no longer executable.
    case chosenMissing(String)
    case notOnPATH

    /// The executable to launch, nil when there is none to run.
    var path: String? {
        switch self {
        case .onPATH(let path), .chosen(let path): path
        case .chosenMissing, .notOnPATH: nil
        }
    }

    var isChosen: Bool {
        switch self {
        case .chosen, .chosenMissing: true
        case .onPATH, .notOnPATH: false
        }
    }
}

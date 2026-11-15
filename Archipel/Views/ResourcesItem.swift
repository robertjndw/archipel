import ArchipelCore
import SwiftUI

/// Status bar icon for the resources popover. It only shows text when there is a warning: processes
/// left running by closed tabs, a worktree using a lot of memory, or a process busy for minutes.
struct ResourcesItem: View {
    @Environment(AppModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        let alerts = model.resources.alerts
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: alerts.isEmpty ? "memorychip" : "exclamationmark.triangle.fill")
                    .foregroundStyle(alerts.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                if let first = alerts.first {
                    Text(ResourceFormat.summary(of: first))
                        .foregroundStyle(.primary)
                    if alerts.count > 1 {
                        Text("+\(alerts.count - 1)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(alerts.isEmpty ? "CPU and memory of your tabs" : alerts.map(ResourceFormat.detail).joined(separator: "\n"))
        .accessibilityLabel("Resources")
        .accessibilityValue(alerts.isEmpty ? "No warnings" : alerts.map(ResourceFormat.detail).joined(separator: ", "))
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            ResourcesPopover()
        }
    }
}

enum ResourceFormat {
    static func memory(_ bytes: UInt64) -> String {
        bytes.formatted(.byteCount(style: .memory, spellsOutZero: false))
    }

    static func cpu(_ percent: Double?) -> String {
        guard let percent else { return "-" }
        return percent < 0.5 ? "0%" : "\(Int(percent.rounded()))%"
    }

    static func summary(of alert: ResourceMonitor.Alert) -> String {
        switch alert {
        case .leftovers(let count): "\(count) left running"
        case .memory(let name, let bytes): "\(name) \(memory(bytes))"
        case .cpu(let label, let percent): "\(label) \(cpu(percent)) CPU"
        }
    }

    static func detail(of alert: ResourceMonitor.Alert) -> String {
        switch alert {
        case .leftovers(let count):
            count == 1 ? "A process is still running after its tab closed" : "\(count) processes are still running after their tabs closed"
        case .memory(let name, let bytes):
            "\(name) uses \(memory(bytes)) of memory"
        case .cpu(let label, let percent):
            "\(label) has used \(cpu(percent)) CPU for over \(Int(ResourceMonitor.cpuWarningDuration / 60)) minutes"
        }
    }
}

// MARK: Popover

private enum ResourceSort: String {
    case name, cpu, memory
}

/// Usage per project, worktree and tab. Processes are collapsed under their tab by default since
/// the per-tab numbers are usually enough.
private struct ResourcesPopover: View {
    @Environment(AppModel.self) private var model
    @AppStorage("resources.sort") private var sort: ResourceSort = .memory
    /// Rows toggled away from their default state, keyed by project, worktree, tab or leftover id.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        let projects = projectGroups
        let leftovers = model.resources.leftovers
        VStack(alignment: .leading, spacing: 0) {
            summary(projects: projects, leftovers: leftovers)
            Divider()
            columnHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !leftovers.isEmpty {
                        LeftoversRows(leftovers: leftovers, isExpanded: binding(for: Self.leftoversID, expandedByDefault: false))
                        Divider()
                    }
                    if projects.isEmpty, leftovers.isEmpty {
                        Text("Nothing is running in your tabs")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                    ForEach(projects) { project in
                        projectRows(project)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)
            Divider()
            ResourceRow(level: 0) {
                Text("Archipel and its terminals")
                    .foregroundStyle(.secondary)
            } metrics: {
                MetricPair(cpu: model.resources.app.cpu, memory: model.resources.app.memory)
            }
        }
        .frame(width: 400)
        .font(.system(size: 12))
        .monospacedDigit()
        .onAppear { model.resources.isWatched = true }
        .onDisappear { model.resources.isWatched = false }
    }

    private static let leftoversID = UUID()

    private func summary(projects: [ProjectGroup], leftovers: [ResourceMonitor.Leftover]) -> some View {
        let memory = projects.reduce(0) { $0 + $1.memory } + leftovers.reduce(0) { $0 + $1.usage.memory }
        let cpu = projects.reduce(0) { $0 + $1.cpu } + leftovers.reduce(0) { $0 + $1.usage.cpu }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(ResourceFormat.cpu(cpu)) CPU")
                .fontWeight(.medium)
            Text("\(Text(ResourceFormat.memory(memory)).fontWeight(.medium)) \(Text("of \(ResourceFormat.memory(ProcessInfo.processInfo.physicalMemory))").foregroundStyle(.secondary))")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .help("Memory is the footprint Activity Monitor shows. CPU above 100% means more than one core is busy.")
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            sortButton("Name", .name)
            Spacer()
            sortButton("CPU", .cpu)
                .frame(width: MetricPair.cpuWidth, alignment: .trailing)
            sortButton("Mem", .memory)
                .frame(width: MetricPair.memoryWidth, alignment: .trailing)
            Color.clear.frame(width: resourceRowGutter, height: 1)
        }
        .font(.system(size: 10))
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
    }

    private func sortButton(_ title: String, _ option: ResourceSort) -> some View {
        Button(title) { sort = option }
            .buttonStyle(.plain)
            .fontWeight(sort == option ? .semibold : .regular)
            .foregroundStyle(sort == option ? .primary : .secondary)
    }

    @ViewBuilder private func projectRows(_ project: ProjectGroup) -> some View {
        let isExpanded = binding(for: project.id, expandedByDefault: true)
        ResourceRow(level: 0, isExpanded: isExpanded) {
            Text(project.name)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } metrics: {
            MetricPair(cpu: project.cpu, memory: project.memory)
        }
        if isExpanded.wrappedValue {
            ForEach(project.worktrees) { worktree in
                worktreeRows(worktree)
            }
        }
        Divider()
    }

    @ViewBuilder private func worktreeRows(_ group: WorktreeGroup) -> some View {
        let isExpanded = binding(for: group.id, expandedByDefault: true)
        ResourceRow(level: 1, isExpanded: isExpanded, action: { model.select(worktree: group.id) }) {
            Text(group.worktree.displayName)
                .lineLimit(1)
        } metrics: {
            Sparkline(values: model.resources.memoryHistory[group.id] ?? [])
                .frame(width: 44, height: 12)
            MetricPair(cpu: group.cpu, memory: group.memory, warnsAbove: ResourceMonitor.memoryWarning)
        }
        .help("Show this worktree")
        if isExpanded.wrappedValue {
            ForEach(group.sessions) { entry in
                sessionRows(entry)
            }
        }
    }

    @ViewBuilder private func sessionRows(_ entry: SessionGroup) -> some View {
        let isExpanded = binding(for: entry.id, expandedByDefault: false)
        ResourceRow(
            level: 2,
            isExpanded: entry.usage.processes.isEmpty ? nil : isExpanded,
            action: { model.select(session: entry.id) }
        ) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.usage.processes.contains(where: \.isHot) ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                    .frame(width: 6, height: 6)
                Text(entry.session.displayTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                SubagentBadge(count: model.activity(for: entry.id).subagents.count)
            }
        } metrics: {
            MetricPair(cpu: entry.usage.cpu, memory: entry.usage.memory)
                .foregroundStyle(.secondary)
        }
        .help("Show this tab")
        if isExpanded.wrappedValue {
            ForEach(sorted(entry.usage.processes)) { process in
                ProcessRowView(row: process, level: 3, confirmsQuit: process.isForeground, owner: entry.session.displayTitle)
            }
        }
    }

    private func binding(for id: UUID, expandedByDefault: Bool) -> Binding<Bool> {
        // Only deviations from the default are stored, so new rows start out in their default state.
        Binding(
            get: { collapsed.contains(id) != expandedByDefault },
            set: { if $0 == expandedByDefault { collapsed.remove(id) } else { collapsed.insert(id) } }
        )
    }

    // MARK: Grouping and sorting

    private var projectGroups: [ProjectGroup] {
        let usage = model.resources.sessions
        var groups: [ProjectGroup] = []
        for island in model.workspace.islands {
            for project in island.projects {
                let worktrees: [WorktreeGroup] = project.worktrees.compactMap { worktree in
                    let sessions = worktree.sessions.compactMap { session in
                        usage[session.id].map { SessionGroup(session: session, usage: $0) }
                    }
                    guard !sessions.isEmpty else { return nil }
                    return WorktreeGroup(worktree: worktree, sessions: sorted(sessions, name: \.session.displayTitle, cpu: \.usage.cpu, memory: \.usage.memory))
                }
                guard !worktrees.isEmpty else { continue }
                groups.append(ProjectGroup(id: project.id, name: project.name,
                                           worktrees: sorted(worktrees, name: \.worktree.displayName, cpu: \.cpu, memory: \.memory)))
            }
        }
        return sorted(groups, name: \.name, cpu: \.cpu, memory: \.memory)
    }

    private func sorted<T>(_ items: [T], name: KeyPath<T, String>, cpu: KeyPath<T, Double>, memory: KeyPath<T, UInt64>) -> [T] {
        switch sort {
        case .name: items.sorted { $0[keyPath: name].localizedStandardCompare($1[keyPath: name]) == .orderedAscending }
        case .cpu: items.sorted { $0[keyPath: cpu] > $1[keyPath: cpu] }
        case .memory: items.sorted { $0[keyPath: memory] > $1[keyPath: memory] }
        }
    }

    private func sorted(_ processes: [ResourceMonitor.ProcessRow]) -> [ResourceMonitor.ProcessRow] {
        switch sort {
        case .name: processes.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        case .cpu: processes.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }
        case .memory: processes.sorted { $0.memory > $1.memory }
        }
    }
}

private struct ProjectGroup: Identifiable {
    var id: Project.ID
    var name: String
    var worktrees: [WorktreeGroup]
    var memory: UInt64 { worktrees.reduce(0) { $0 + $1.memory } }
    var cpu: Double { worktrees.reduce(0) { $0 + $1.cpu } }
}

private struct WorktreeGroup: Identifiable {
    var worktree: Worktree
    var sessions: [SessionGroup]
    var id: Worktree.ID { worktree.id }
    var memory: UInt64 { sessions.reduce(0) { $0 + $1.usage.memory } }
    var cpu: Double { sessions.reduce(0) { $0 + $1.usage.cpu } }
}

private struct SessionGroup: Identifiable {
    var session: Session
    var usage: ResourceMonitor.Usage
    var id: Session.ID { session.id }
}

// MARK: Rows

/// Room for a row's quit button, kept on every row so the metric columns line up.
private let resourceRowGutter: CGFloat = 16

/// One line of the tree: indent, an optional disclosure chevron, the name, then the metric columns.
/// `action` makes the name clickable; the chevron always only folds.
private struct ResourceRow<Label: View, Metrics: View, Trailing: View>: View {
    let level: Int
    var isExpanded: Binding<Bool>?
    var action: (() -> Void)?
    @ViewBuilder let label: Label
    @ViewBuilder let metrics: Metrics
    @ViewBuilder let trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if let isExpanded {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                            .frame(width: 12, height: 16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded.wrappedValue ? "Collapse" : "Expand")
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                if let action {
                    Button(action: action) { label.contentShape(.rect) }
                        .buttonStyle(.plain)
                } else {
                    label
                }
            }
            .padding(.leading, CGFloat(level) * 14)
            Spacer(minLength: 8)
            metrics
            trailing
                .frame(width: resourceRowGutter)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isHovered && action != nil ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
    }
}

extension ResourceRow where Trailing == EmptyView {
    init(level: Int, isExpanded: Binding<Bool>? = nil, action: (() -> Void)? = nil,
         @ViewBuilder label: () -> Label, @ViewBuilder metrics: () -> Metrics) {
        self.init(level: level, isExpanded: isExpanded, action: action, label: label, metrics: metrics, trailing: { EmptyView() })
    }
}

private struct LeftoversRows: View {
    @Environment(AppModel.self) private var model
    let leftovers: [ResourceMonitor.Leftover]
    @Binding var isExpanded: Bool

    var body: some View {
        let count = leftovers.reduce(0) { $0 + $1.usage.processes.count }
        VStack(spacing: 0) {
            ResourceRow(level: 0, isExpanded: $isExpanded) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(count == 1 ? "1 process left running" : "\(count) processes left running")
                        .fontWeight(.medium)
                    Button("Quit All") {
                        model.resources.quit(leftovers.flatMap { $0.usage.processes.map(\.id) })
                    }
                    .controlSize(.mini)
                }
            } metrics: {
                MetricPair(cpu: leftovers.reduce(0) { $0 + $1.usage.cpu }, memory: leftovers.reduce(0) { $0 + $1.usage.memory })
            }
            .help("Still running after the tab that started them closed")
            if isExpanded {
                ForEach(leftovers) { leftover in
                    ResourceRow(level: 1) {
                        Text(leftover.origin)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } metrics: {
                        MetricPair(cpu: leftover.usage.cpu, memory: leftover.usage.memory)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(leftover.usage.processes) { process in
                        ProcessRowView(row: process, level: 2, confirmsQuit: false, owner: leftover.origin)
                    }
                }
            }
        }
        .background(.orange.opacity(0.08))
    }
}

private struct ProcessRowView: View {
    @Environment(AppModel.self) private var model
    let row: ResourceMonitor.ProcessRow
    let level: Int
    let confirmsQuit: Bool
    let owner: String
    @State private var isHovered = false
    @State private var confirming = false

    var body: some View {
        ResourceRow(level: level) {
            HStack(spacing: 6) {
                Text(row.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(row.id.pid)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if row.isHot {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                        .help("Above \(Int(ResourceMonitor.cpuWarning))% CPU for over \(Int(ResourceMonitor.cpuWarningDuration / 60)) minutes")
                }
            }
        } metrics: {
            MetricPair(cpu: row.cpu, memory: row.memory)
                .foregroundStyle(.secondary)
        } trailing: {
            Button {
                if confirmsQuit { confirming = true } else { model.resources.quit([row.id]) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            // Hidden rather than removed so the columns do not shift under the pointer.
            .opacity(isHovered || confirming ? 1 : 0)
            .help("Quit \(row.label)")
            .accessibilityLabel("Quit \(row.label)")
        }
        .onHover { isHovered = $0 }
        .confirmationDialog("Quit \(row.label)?", isPresented: $confirming) {
            Button("Quit", role: .destructive) { model.resources.quit([row.id]) }
        } message: {
            Text("\(owner) is running it, so the tab stops too.")
        }
    }
}

private struct MetricPair: View {
    static let cpuWidth: CGFloat = 40
    static let memoryWidth: CGFloat = 64
    let cpu: Double?
    let memory: UInt64
    var warnsAbove: UInt64?

    var body: some View {
        HStack(spacing: 8) {
            Text(ResourceFormat.cpu(cpu))
                .frame(width: Self.cpuWidth, alignment: .trailing)
            Text(ResourceFormat.memory(memory))
                .foregroundStyle(warnsAbove.map { memory >= $0 } == true ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .frame(width: Self.memoryWidth, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

/// The shape of a worktree's recent memory. Scaled to its own range, so it shows a trend, not a size.
private struct Sparkline: View {
    let values: [UInt64]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let range = Double(high - low)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * Double(index) / Double(values.count - 1)
                // A flat line sits in the middle instead of on the floor.
                let fraction = range > 0 ? Double(value - low) / range : 0.5
                let point = CGPoint(x: x, y: size.height * (1 - fraction))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .style(.secondary), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

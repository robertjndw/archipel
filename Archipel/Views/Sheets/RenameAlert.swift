import ArchipelCore
import SwiftUI

struct RenameTarget: Identifiable {
    enum Kind {
        case project(Project.ID)
        case session(Session.ID)
    }

    let id = UUID()
    var kind: Kind
    var name: String
}

extension View {
    func renameAlert(_ target: Binding<RenameTarget?>) -> some View {
        modifier(RenameAlert(target: target))
    }
}

private struct RenameAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var target: RenameTarget?

    func body(content: Content) -> some View {
        content.alert("Rename", item: $target) { target in
            RenameFields(target: target) { name in
                switch target.kind {
                case .project(let id): model.renameProject(id, to: name)
                case .session(let id): model.renameSession(id, to: name)
                }
            }
        }
    }
}

private struct RenameFields: View {
    let target: RenameTarget
    let commit: (String) -> Void
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
            .onAppear { name = target.name }
        Button("Rename") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { commit(trimmed) }
        }
        Button("Cancel", role: .cancel) {}
    }
}

#if DEBUG
#Preview("Project") {
    @Previewable @State var target: RenameTarget? = RenameTarget(kind: .project(PreviewFixtures.appProjectID), name: "Orbit")
    Color.clear
        .frame(width: 400, height: 300)
        .renameAlert($target)
        .environment(AppModel.preview())
}

#Preview("Session") {
    @Previewable @State var target: RenameTarget? = RenameTarget(kind: .session(PreviewFixtures.reviewSessionID), name: "Review")
    Color.clear
        .frame(width: 400, height: 300)
        .renameAlert($target)
        .environment(AppModel.preview())
}
#endif

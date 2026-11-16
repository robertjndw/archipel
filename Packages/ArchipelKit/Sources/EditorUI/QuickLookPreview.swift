import Quartz
import SwiftUI

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    /// Changes whenever the file changes on disk, so the preview reloads.
    let revision: Int

    final class Coordinator {
        var revision = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        } else if context.coordinator.revision != revision {
            view.refreshPreviewItem()
        }
        context.coordinator.revision = revision
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

import AppKit
import Quartz

/// NSView that can show a photo in Quick Look (same panel as Space in Finder).
/// Click again on the same photo (or Esc) to close it.
class QuickLookView: NSView, QLPreviewPanelDataSource {
    var previewURL: URL?
    private var shownURL: URL?

    override var acceptsFirstResponder: Bool { true }

    func toggleQuickLook() {
        guard let url = previewURL, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, shownURL == url {
            panel.orderOut(nil)
            shownURL = nil
            return
        }
        shownURL = url
        window?.makeFirstResponder(self)
        if panel.isVisible {
            panel.updateController()
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        shownURL = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { shownURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        shownURL as NSURL?
    }
}

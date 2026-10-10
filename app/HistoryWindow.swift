import Cocoa

/// All call notes in one window: a searchable list on the left, the selected note on the right.
final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let app: AppDelegate
    var window: NSWindow!
    var table: NSTableView!
    var search: NSSearchField!
    var noteView: NSTextView!
    var openButton: NSButton!
    var notes: [(note: RecentNote, text: String)] = []
    var shown: [(note: RecentNote, text: String)] = []
    var folder: URL { app.projectDir.appendingPathComponent("notlar") }

    init(app: AppDelegate) { self.app = app; super.init(); build() }
    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 580), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Asistan — Görüşmeler"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        let content = window.contentView!, b = content.bounds
        search = NSSearchField(frame: NSRect(x: 12, y: b.height - 40, width: 276, height: 26))
        search.placeholderString = "Ad, numara ya da özette ara"; search.delegate = self
        search.autoresizingMask = [.minYMargin]; content.addSubview(search)
        let listScroll = NSScrollView(frame: NSRect(x: 12, y: 50, width: 276, height: b.height - 100))
        listScroll.hasVerticalScroller = true; listScroll.borderType = .bezelBorder; listScroll.autoresizingMask = [.height]
        table = NSTableView(frame: listScroll.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note")); column.title = "Görüşme"; column.width = 256
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 22
        table.dataSource = self; table.delegate = self
        listScroll.documentView = table; content.addSubview(listScroll)
        let textScroll = NSScrollView(frame: NSRect(x: 300, y: 50, width: b.width - 312, height: b.height - 62))
        textScroll.hasVerticalScroller = true; textScroll.borderType = .bezelBorder; textScroll.autoresizingMask = [.width, .height]
        noteView = NSTextView(frame: textScroll.bounds)
        noteView.isEditable = false; noteView.font = .systemFont(ofSize: 13); noteView.textContainerInset = NSSize(width: 10, height: 10)
        noteView.isVerticallyResizable = true; noteView.autoresizingMask = [.width]; noteView.textContainer?.widthTracksTextView = true
        textScroll.documentView = noteView; content.addSubview(textScroll)
        openButton = NSButton(title: "TextEdit'te aç", target: self, action: #selector(openSelected)); openButton.bezelStyle = .rounded
        openButton.frame = NSRect(x: 300, y: 12, width: 150, height: 30); content.addSubview(openButton)
        let folderButton = NSButton(title: "Notlar klasörü", target: self, action: #selector(openFolder)); folderButton.bezelStyle = .rounded
        folderButton.frame = NSRect(x: 12, y: 12, width: 150, height: 30); content.addSubview(folderButton)
    }
    func show() {
        reload()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func reload() {
        notes = RecentNotes.list(in: folder, limit: 500).map { ($0, (try? String(contentsOf: $0.url, encoding: .utf8)) ?? "") }
        filter()
    }
    func filter() {
        let query = AssistantPreferences.normalized(search.stringValue)
        shown = query.isEmpty ? notes : notes.filter { AssistantPreferences.normalized($0.note.title + " " + $0.text).contains(query) }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        showSelected()
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: shown[row].note.title)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }
    func showSelected() {
        let row = table.selectedRow
        openButton.isEnabled = row >= 0 && row < shown.count
        noteView.string = row >= 0 && row < shown.count ? shown[row].text : (notes.isEmpty ? "Henüz görüşme notu yok." : "Eşleşen görüşme yok.")
        noteView.scrollToBeginningOfDocument(nil)
    }
    @objc func openSelected() {
        let row = table.selectedRow
        if row >= 0 && row < shown.count { app.openInTextEdit(shown[row].note.url) }
    }
    @objc func openFolder() { NSWorkspace.shared.open(folder) }
}

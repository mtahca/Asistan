import Cocoa

/// A settings area built by its own controller; its controls move into the shared window.
protocol SettingsPane: AnyObject {
    var window: NSWindow! { get set }
    /// Loads current values. Called once each time the window opens, when the tab is first shown,
    /// so unsaved edits survive switching tabs.
    func prepare()
    func paneClosed()
}

/// One window with a tab per settings area instead of five separate windows.
final class SettingsWindow: NSObject, NSWindowDelegate, NSTabViewDelegate {
    let window: NSWindow
    private let tabs: NSTabView
    private var panes: [String: SettingsPane] = [:]
    private var prepared: Set<String> = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 790), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Asistan — Ayarlar"; window.isReleasedWhenClosed = false
        tabs = NSTabView(frame: window.contentView!.bounds.insetBy(dx: 6, dy: 6))
        tabs.autoresizingMask = [.width, .height]
        super.init()
        window.delegate = self
        window.contentView!.addSubview(tabs)
    }
    func add(_ id: String, _ label: String, _ pane: SettingsPane) {
        guard let content = pane.window.contentView else { return }
        pane.window.contentView = NSView()
        let container = NSView(frame: tabs.contentRect)
        // Panes were laid out for their own windows: keep them top-centred in the tab.
        content.setFrameOrigin(NSPoint(x: max(0, (container.bounds.width - content.frame.width) / 2),
                                       y: container.bounds.height - content.frame.height))
        content.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(content)
        let item = NSTabViewItem(identifier: id); item.label = label; item.view = container
        tabs.addTabViewItem(item)
        pane.window = window
        panes[id] = pane
    }
    /// Delegate is set after all tabs exist so building the window prepares nothing.
    func finish() { tabs.delegate = self }
    func show(_ id: String) {
        if tabs.selectedTabViewItem?.identifier as? String != id { tabs.selectTabViewItem(withIdentifier: id) }
        prepareIfNeeded(id)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func prepareIfNeeded(_ id: String) {
        guard !prepared.contains(id), let pane = panes[id] else { return }
        prepared.insert(id); pane.prepare()
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let id = tabViewItem?.identifier as? String { prepareIfNeeded(id) }
    }
    func windowWillClose(_ notification: Notification) {
        prepared.removeAll()
        for pane in panes.values { pane.paneClosed() }
    }
}

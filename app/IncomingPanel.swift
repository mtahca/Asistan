import Cocoa
import UserNotifications

/// Borderless panels cannot become key by default; this one may after a click so Return and Escape work.
final class IncomingCallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension AppDelegate {
    // MARK: Panel (gelen aramada gösterilen küçük pencere)

    func buildPanel() {
        let w: CGFloat = 330, h: CGFloat = 96
        let p = IncomingCallPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true

        panelIcon = NSImageView(frame: NSRect(x: 16, y: 62, width: 20, height: 20))
        panelIcon.contentTintColor = .systemGreen
        fx.addSubview(panelIcon)
        panelTitle = NSTextField(labelWithString: "Gelen arama")
        panelTitle.font = NSFont.boldSystemFont(ofSize: 14)
        panelTitle.lineBreakMode = .byTruncatingTail
        panelTitle.frame = NSRect(x: 42, y: 62, width: w - 58, height: 20)
        fx.addSubview(panelTitle)

        answerButton = NSButton(title: "Asistan ile Cevapla", target: self, action: #selector(answerWithAssistant))
        answerButton.bezelStyle = .rounded
        answerButton.keyEquivalent = "\r"
        answerButton.frame = NSRect(x: 16, y: 16, width: 190, height: 32)
        fx.addSubview(answerButton)

        let close = NSButton(title: "Kapat", target: self, action: #selector(dismissPanel))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.frame = NSRect(x: 216, y: 16, width: 98, height: 32)
        fx.addSubview(close)

        p.contentView = fx
        panel = p
    }

    func showPanel() {
        if panel.isVisible { return }
        let ready = agentReady && !busy && loopbackAudioReady()
        panelTitle.stringValue = ready ? "Gelen arama" : (busy ? "Asistan başka görüşmede" : "Asistan yükleniyor…")
        answerButton.isEnabled = ready
        updatePanelIcon()
        if let s = NSScreen.main {
            let f = s.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
    }

    func updatePanelIcon() {
        let symbol = bannerSource == .whatsapp ? "message.fill" : "phone.fill"
        panelIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: bannerSource == .whatsapp ? "WhatsApp" : "Telefon")
    }

    func hidePanel() { if panel.isVisible { panel.orderOut(nil) } }

    @objc func dismissPanel() {
        dismissed = true
        hidePanel()
    }
}

// MARK: - Gelen arama bildirimi

extension AppDelegate: UNUserNotificationCenterDelegate {
    static let incomingCategory = "ASISTAN_INCOMING_CALL"
    static let incomingIdentifier = "asistan-incoming-call"
    static let answerAction = "ASISTAN_ANSWER"

    func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let answer = UNNotificationAction(identifier: Self.answerAction, title: "Asistanla cevapla", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.incomingCategory, actions: [answer], intentIdentifiers: [], options: [])])
    }
    /// Lets the call be answered from Notification Center too; withdrawn when the ring ends.
    func postIncomingNotification(ringer: String, source: CallSource) {
        let content = UNMutableNotificationContent()
        content.title = source == .whatsapp ? "Gelen WhatsApp araması" : "Gelen arama"
        content.body = ringer
        content.categoryIdentifier = Self.incomingCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.incomingIdentifier, content: content, trigger: nil))
    }
    func withdrawIncomingNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.incomingIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.incomingIdentifier])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let answer = response.actionIdentifier == Self.answerAction
        DispatchQueue.main.async { [weak self] in
            // Only the ring the notification was posted for; a stale tap does nothing.
            if answer, let self = self, self.offerToken != nil, !self.dismissed, !self.busy { self.beginAnswer(manual: true) }
            completionHandler()
        }
    }
}

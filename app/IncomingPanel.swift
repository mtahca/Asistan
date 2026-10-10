import Cocoa

extension AppDelegate {
    // MARK: Panel (gelen aramada gösterilen küçük pencere)

    func buildPanel() {
        let w: CGFloat = 330, h: CGFloat = 96
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
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

        panelTitle = NSTextField(labelWithString: "Gelen arama")
        panelTitle.font = NSFont.boldSystemFont(ofSize: 14)
        panelTitle.frame = NSRect(x: 16, y: 62, width: w - 32, height: 20)
        fx.addSubview(panelTitle)

        answerButton = NSButton(title: "Asistan ile Cevapla", target: self, action: #selector(answerWithAssistant))
        answerButton.bezelStyle = .rounded
        answerButton.frame = NSRect(x: 16, y: 16, width: 190, height: 32)
        fx.addSubview(answerButton)

        let close = NSButton(title: "Kapat", target: self, action: #selector(dismissPanel))
        close.bezelStyle = .rounded
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
        if let s = NSScreen.main {
            let f = s.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
    }

    func hidePanel() { if panel.isVisible { panel.orderOut(nil) } }

    @objc func dismissPanel() {
        dismissed = true
        hidePanel()
    }
}

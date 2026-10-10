import Cocoa

extension AppDelegate {
    // MARK: Canlı görüşme metni

    func buildLiveWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 570),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Asistan — Canlı görüşme"
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces]
        w.minSize = NSSize(width: 480, height: 400)
        let cb = w.contentView!.bounds
        liveStatus = NSTextField(labelWithString: "Görüşme bekleniyor")
        liveStatus.frame = NSRect(x: 12, y: cb.height - 28, width: cb.width - 24, height: 20)
        liveStatus.autoresizingMask = [.width, .minYMargin]
        liveStatus.textColor = .secondaryLabelColor; w.contentView!.addSubview(liveStatus)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 86, width: cb.width, height: cb.height - 120))
        sv.hasVerticalScroller = true
        sv.autoresizingMask = [.width, .height]

        let field = NSTextField(frame: NSRect(x: 10, y: 12, width: cb.width - 114, height: 26))
        field.placeholderString = "Asistan’a not yaz (Enter ile gönder)"
        field.autoresizingMask = [.width]
        field.target = self
        field.action = #selector(sendNote)
        w.contentView!.addSubview(field)
        noteField = field
        let send = NSButton(title: "Gönder", target: self, action: #selector(sendNote))
        send.bezelStyle = .rounded
        send.frame = NSRect(x: cb.width - 92, y: 10, width: 82, height: 30)
        send.autoresizingMask = [.minXMargin]
        w.contentView!.addSubview(send); sendButton = send
        let endBtn = NSButton(title: "Sonlandır", target: self, action: #selector(endSession))
        endBtn.bezelStyle = .rounded
        endBtn.frame = NSRect(x: cb.width - 110, y: 48, width: 100, height: 30)
        endBtn.autoresizingMask = [.minXMargin]
        w.contentView!.addSubview(endBtn); endButton = endBtn
        let take = NSButton(title: "Devral", target: self, action: #selector(takeOver))
        take.bezelStyle = .rounded
        take.bezelColor = .systemOrange
        take.frame = NSRect(x: cb.width - 218, y: 48, width: 100, height: 30)
        take.autoresizingMask = [.minXMargin]
        w.contentView!.addSubview(take); takeButton = take
        let copy = NSButton(title: "Kopyala", target: self, action: #selector(copyTranscript))
        copy.bezelStyle = .rounded; copy.toolTip = "Canlı metni panoya kopyala"
        copy.frame = NSRect(x: 10, y: 48, width: 90, height: 30)
        w.contentView!.addSubview(copy)
        let presets = NSPopUpButton(frame: NSRect(x: 106, y: 50, width: 150, height: 26), pullsDown: true)
        quickNotePopup = presets; rebuildQuickNotes()
        presets.target = self; presets.action = #selector(chooseQuickNote(_:))
        presets.toolTip = "Seçilen not yazı alanına eklenir; Enter ile gönderin."
        w.contentView!.addSubview(presets)
        let tv = NSTextView(frame: sv.bounds)
        tv.isEditable = false
        tv.isRichText = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.textContainer?.widthTracksTextView = true
        sv.documentView = tv
        w.contentView!.addSubview(sv)
        if let s = NSScreen.main {
            let f = s.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.maxX - 580, y: f.maxY - 600))
        }
        liveWindow = w
        liveText = tv
    }

    /// Notes are edited in Kişiselleştirme; the first item is the pull-down's title.
    func rebuildQuickNotes() {
        quickNotePopup.removeAllItems(); quickNotePopup.addItem(withTitle: "Hazır notlar")
        for text in QuickNotes.load() { quickNotePopup.addItem(withTitle: text); quickNotePopup.lastItem?.representedObject = text }
    }
    @objc func chooseQuickNote(_ sender: NSPopUpButton) {
        guard let text = sender.selectedItem?.representedObject as? String else { return }
        noteField.stringValue = text
        liveWindow.makeFirstResponder(noteField)
    }
    @objc func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(liveText.string, forType: .string)
    }
    /// Follow new lines only while the reader is at the bottom; reading earlier lines must not jump.
    func liveAtBottom() -> Bool {
        guard let clip = liveText.enclosingScrollView?.contentView else { return true }
        return clip.bounds.maxY >= liveText.frame.height - 40
    }
    func scrollLiveIfFollowing() { if liveFollow { liveText.scrollToEndOfDocument(nil) } }

    func renderLiveTranscript() {
        var phoneRows: [(String, String, String)] = []
        if !liveCallerHeading.isEmpty { phoneRows.append(("note", "", liveCallerHeading)) }
        for row in liveRows {
            let speaker = row["speaker"] as? String ?? ""
            phoneRows.append((speaker == "Arayan" ? "caller" : "assistant", speaker, row["text"] as? String ?? ""))
        }
        for (speaker, text, color) in liveExtras { phoneRows.append((color == nil ? "note" : "you", speaker, text)) }
        mobile.replace(phoneRows)
        liveFollow = liveAtBottom()
        let offset = liveText.enclosingScrollView?.contentView.bounds.origin
        renderingLive = true
        defer {
            renderingLive = false
            if !liveFollow, let offset = offset, let scroll = liveText.enclosingScrollView {
                scroll.contentView.scroll(to: offset); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        liveText.string = ""
        appendLiveNote(liveCallerHeading)
        for row in liveRows {
            let speaker = row["speaker"] as? String ?? ""
            appendLive(speaker, row["text"] as? String ?? "", color: speaker == "Arayan" ? .systemBlue : .systemGreen)
        }
        for (speaker, text, color) in liveExtras {
            if let color = color { appendLive(speaker, text, color: color) }
            else { appendLiveNote(text) }
        }
    }
    func appendLive(_ speaker: String, _ text: String, color: NSColor) {
        if !renderingLive {
            liveFollow = liveAtBottom()
            liveExtras.append((speaker, text, color))
            mobile.append(kind: speaker == "Arayan" ? "caller" : (speaker == "Asistan" ? "assistant" : "you"), speaker: speaker, text: text)
        }
        // A tinted block per message, like the phone: the caller on the left, everyone else on the right.
        let block = NSTextBlock()
        block.backgroundColor = color.withAlphaComponent(0.13)
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(speaker == "Arayan" ? 70 : 0, type: .absoluteValueType, for: .margin, edge: .maxX)
        block.setWidth(speaker == "Arayan" ? 0 : 70, type: .absoluteValueType, for: .margin, edge: .minX)
        let style = NSMutableParagraphStyle(); style.textBlocks = [block]
        let a = NSMutableAttributedString()
        a.append(NSAttributedString(string: speaker + "\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: style]))
        a.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
        a.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        liveText.textStorage?.append(a)
        scrollLiveIfFollowing()
    }

    func appendLiveNote(_ text: String) {
        if !renderingLive {
            liveFollow = liveAtBottom()
            if text != liveCallerHeading { liveExtras.append(("", text, nil)) }
            mobile.append(kind: text.contains("Arayan araya girdi") ? "interrupted" : "note", speaker: "", text: text)
        }
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        liveText.textStorage?.append(NSAttributedString(string: text + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered]))
        scrollLiveIfFollowing()
    }

    /// Yazılan notu çalışan ajana iletir; ajan bunu konuşmanın akışında arayana söyler
    @objc func sendNote() {
        if deliverNote(noteField.stringValue, fromPhone: false) { noteField.stringValue = "" }
    }
    @discardableResult func deliverNote(_ raw: String, fromPhone: Bool) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, inSession, stoppingDeadline == nil, let sid = sessionID else { appendLiveNote("Not gönderilemedi: etkin görüşme yok."); return false }
        guard text.unicodeScalars.count <= 1000 else { appendLiveNote("Not en fazla 1000 karakter olabilir."); return false }
        if sendCommand(["command": "note", "session_id": sid, "note_id": UUID().uuidString, "text": text]) {
            appendLive(fromPhone ? "iPhone'dan notun" : "Senin notun", text + " (kabul bekleniyor)", color: .systemPurple)
            return true
        }
        appendLiveNote("Not gönderilemedi; yeniden deneyin."); return false
    }
}

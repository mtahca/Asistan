import Cocoa
import ApplicationServices
import AVFoundation
import Contacts

final class SetupController: NSObject, NSWindowDelegate {
    let app: AppDelegate
    var window: NSWindow!
    var labels: [String: NSTextField] = [:]
    var logView: NSTextView!
    var installButton: NSButton!
    var finishButton: NSButton!
    var testButton: NSButton!
    var feedback: NSTextField!
    var timer: Timer?
    var installing = false
    var checkingAPI = false
    var checkProcess: Process?
    var checkedSettings: String?
    var checkGeneration = UUID()
    init(app: AppDelegate) { self.app = app; super.init(); build() }
    func label(_ text: String, at rect: NSRect, in parent: NSView, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.frame = rect; field.font = bold ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 12)
        field.isSelectable = true; parent.addSubview(field); return field
    }
    func button(_ text: String, action: Selector, at rect: NSRect, in parent: NSView) -> NSButton {
        let view = NSButton(title: text, target: self, action: action)
        view.bezelStyle = .rounded; view.frame = rect; parent.addSubview(view); return view
    }
    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 690), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Asistan — Kurulum ve durum"; window.isReleasedWhenClosed = false; window.delegate = self
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Bilinmiyor"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Bilinmiyor"
        _ = label("Asistan · Sürüm \(version) · Derleme \(build)", at: NSRect(x: 24, y: 653, width: 572, height: 23), in: window.contentView!, bold: true)
        let tabs = NSTabView(frame: NSRect(x: 20, y: 64, width: 580, height: 576))
        let statusTab = NSTabViewItem(identifier: "status"); statusTab.label = "Durum ve kontroller"
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 535))
        labels["status"] = label("", at: NSRect(x: 12, y: 490, width: 536, height: 28), in: page, bold: true)
        labels["detail"] = label("", at: NSRect(x: 12, y: 436, width: 536, height: 50), in: page)
        labels["audio"] = label("", at: NSRect(x: 12, y: 364, width: 350, height: 64), in: page)
        _ = button("Ses ayarları…", action: #selector(soundSettings), at: NSRect(x: 390, y: 383, width: 158, height: 30), in: page)
        labels["py"] = label("", at: NSRect(x: 12, y: 309, width: 278, height: 40), in: page)
        installButton = button("Ortamı kur (internet gerekir)", action: #selector(runInstall), at: NSRect(x: 294, y: 315, width: 254, height: 30), in: page)
        labels["models"] = label("", at: NSRect(x: 12, y: 253, width: 536, height: 54), in: page)
        _ = button("Modeller ve API anahtarları…", action: #selector(modelSettings), at: NSRect(x: 12, y: 217, width: 268, height: 30), in: page)
        labels["keys"] = label("", at: NSRect(x: 12, y: 169, width: 536, height: 42), in: page)
        testButton = button("Seçili modellerin bağlantısını sına", action: #selector(checkAPI), at: NSRect(x: 12, y: 132, width: 300, height: 30), in: page)
        labels["perms"] = label("", at: NSRect(x: 12, y: 83, width: 536, height: 44), in: page)
        _ = button("İzinleri iste", action: #selector(askPerms), at: NSRect(x: 12, y: 44, width: 140, height: 30), in: page)
        _ = button("İzin ayarlarını aç", action: #selector(openPermissionSettings), at: NSRect(x: 164, y: 44, width: 172, height: 30), in: page)
        _ = label("Bağlantı testi küçük bir API isteği gönderir; ücret oluşabilir. Görüşme ve rehber içeriği gönderilmez.", at: NSRect(x: 12, y: 0, width: 536, height: 38), in: page)
        statusTab.view = page; tabs.addTabViewItem(statusTab)
        let detailsTab = NSTabViewItem(identifier: "details"); detailsTab.label = "Kurulum ayrıntıları"
        let details = NSView(frame: page.frame)
        _ = label("İzin anahtarı açık görünse de çalışan Asistan izni kullanamayabilir. Asistan’dan çıkıp erişilebilirlik listesindeki kaydı güncel uygulamayla yenileyin ve yeniden açın. Eski Asistan Beta kaydını listeden kaldırabilirsiniz.", at: NSRect(x: 12, y: 459, width: 536, height: 60), in: details)
        _ = button("Uygulama dosyasını göster", action: #selector(revealApplication), at: NSRect(x: 12, y: 419, width: 258, height: 30), in: details)
        _ = label("Kurulum günlüğü", at: NSRect(x: 12, y: 380, width: 536, height: 24), in: details, bold: true)
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 38, width: 536, height: 331)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        logView = NSTextView(frame: scroll.bounds); logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular); logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true; logView.textContainer?.widthTracksTextView = true
        scroll.documentView = logView; details.addSubview(scroll)
        detailsTab.view = details; tabs.addTabViewItem(detailsTab)
        let remoteTab = NSTabViewItem(identifier: "mobile"); remoteTab.label = "iPhone ve Odak"
        let remote = NSView(frame: page.frame)
        _ = label("Asistan Mobile", at: NSRect(x: 12, y: 482, width: 536, height: 28), in: remote, bold: true)
        labels["mobile"] = label("", at: NSRect(x: 12, y: 421, width: 536, height: 54), in: remote)
        _ = label("Telefondan gelen aramayı Asistan ile cevaplayabilir, etkin görüşmeye not gönderebilir, canlı metni izleyebilir ve görüşmeyi sonlandırabilirsiniz. Aynı Wi-Fi ve bu Mac’in eşleştirme kodu gerekir.", at: NSRect(x: 12, y: 332, width: 536, height: 80), in: remote)
        _ = button("Mobil bağlantı ve eşleştirme…", action: #selector(mobileSettings), at: NSRect(x: 12, y: 288, width: 310, height: 32), in: remote)
        _ = label("Odak sırasında otomatik cevaplama", at: NSRect(x: 12, y: 224, width: 536, height: 28), in: remote, bold: true)
        labels["focus"] = label("", at: NSRect(x: 12, y: 149, width: 536, height: 65), in: remote)
        _ = label("İsteğe bağlıdır. Odak durumu okunamıyorsa Tam Disk Erişimi gerekebilir. Bu izin mobil bağlantı, ses ve elle cevaplama için gerekmez. Duraklatma açıkken otomatik cevap verilmez.", at: NSRect(x: 12, y: 60, width: 536, height: 80), in: remote)
        _ = button("Odak ayarlarını aç…", action: #selector(mobileSettings), at: NSRect(x: 12, y: 16, width: 310, height: 32), in: remote)
        remoteTab.view = remote; tabs.addTabViewItem(remoteTab)
        window.contentView!.addSubview(tabs)
        feedback = label("", at: NSRect(x: 24, y: 10, width: 392, height: 44), in: window.contentView!)
        finishButton = button("Başlat / Kapat", action: #selector(finish), at: NSRect(x: 430, y: 14, width: 166, height: 32), in: window.contentView!)
    }
    func show() {
        refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
    func log(_ text: String) {
        logView.textStorage?.append(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]))
        logView.scrollToEndOfDocument(nil)
    }
    func invalidateAPICheck() {
        if checkedSettings != nil { feedback?.stringValue = "Ayarlar değişti. Bağlantıyı yeniden sınayın." }
        checkedSettings = nil
    }
    func stopAPICheck() {
        checkGeneration = UUID()
        if checkProcess?.isRunning == true { checkProcess?.terminate() }
    }
    func refresh() {
        let status = app.setupStatus(); let values = app.savedSettings()
        app.focusMonitor.refresh(enabled: app.focusAuto)
        labels["mobile"]?.stringValue = app.mobile.status + (app.mobile.enabled ? "\nTelefonda seçilecek Mac: " + app.mobile.macName : "\nVarsayılan olarak kapalı. Eşleştirme ekranından açabilirsiniz.")
        labels["focus"]?.stringValue = app.focusAuto ? app.focusMonitor.status + (app.focusMonitor.active == nil ? "\nAsistan’a Tam Disk Erişimi verip yeniden açın." : "") : "Odak sırasında otomatik cevaplama kapalı."

        labels["status"]?.stringValue = app.statusLine.title.isEmpty ? "Kurulum kontrol ediliyor" : app.statusLine.title
        let ready = status.audio && status.py && status.key && status.perms && app.agentReady && !app.paused && !app.busy
        if app.busy { labels["detail"]?.stringValue = "Görüşme devam ediyor. Model, anahtar ve bağlantı testini görüşme bittikten sonra değiştirebilirsiniz." }
        else if app.paused { labels["detail"]?.stringValue = "Menüden arama karşılamayı yeniden etkinleştirin. Duraklatma açıkken yeni aramalar karşılanmaz." }
        else { labels["detail"]?.stringValue = ready ? "Arama karşılamaya hazır. Model bağlantısını aşağıdan ayrıca sınayabilirsiniz." : (!status.perms ? "Erişilebilirlik ve mikrofon izinlerini tamamlayın. İşaretler çalışan uygulamanın kullandığı izni gösterir." : (!status.audio ? "Eksik Loopback aygıtlarını Ses ayarları bölümünden kontrol edin." : (!status.py ? "Önce yerel konuşma ortamını kurun." : (!status.key ? "Seçili modellerin anahtarlarını Modeller ve API anahtarları bölümünden girin." : (app.agentFailure ?? app.preparationText))))) }
        func mark(_ good: Bool) -> String { good ? "✓ " : "○ " }
        labels["audio"]?.stringValue = mark(namedAudioDevice(BetaAudio.listenName, input: true) != nil) + "Asistan Dinleme\n" + mark(namedAudioDevice(BetaAudio.playbackName, input: false) != nil) + "Asistan Ses Çıkışı\n" + mark(namedAudioDevice(BetaAudio.microphoneName, input: true) != nil) + "Asistan Mikrofonu"
        let online = (try? BetaModelConfiguration.voiceMode(in: values)) == "gpt-live"
        let localModelState = online ? "GPT-Live · yerel ses modeli gerekmez" : (app.localModelsReady ? "✓ Whisper ve Türkçe ses sınandı" : (app.agent?.isRunning == true && app.agentFailure == nil ? "… Yerel modeller hazırlanıyor" : "○ Modeller başlatıldığında sınanır"))
        labels["py"]?.stringValue = mark(status.py) + (online ? "Ses bağlantısı ortamı\n" : "Yerel konuşma ortamı\n") + localModelState
        do {
            let choices = try BetaModelConfiguration.choices(in: values)
            labels["models"]?.stringValue = (online ? "Ses: GPT-Live 1 (" + (try BetaModelConfiguration.liveVoice(in: values)).capitalized + ") · Arka plan: " : "Görüşme: ") + choices.conversation.display + "\nÖzet: " + choices.summary.display
            let providers = try BetaModelConfiguration.requiredProviders(in: values)
            labels["keys"]?.stringValue = providers.map { provider in
                let exists = (values[BetaModelConfiguration.credentialKeys[provider]!]?.count ?? 0) > 20
                return (provider == "openai" ? "OpenAI" : "Anthropic") + ": " + (exists ? "anahtar kayıtlı" : "anahtar eksik")
            }.joined(separator: " · ") + "\nHesap ve model erişimi bağlantı testiyle doğrulanır."
        } catch { labels["models"]?.stringValue = error.localizedDescription; labels["keys"]?.stringValue = "Model ayarlarını yeniden kaydedin." }
        let ax = AXIsProcessTrusted(), mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let contacts = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        labels["perms"]?.stringValue = mark(ax) + "Erişilebilirlik · " + mark(mic) + "Mikrofon\nRehber: " + (contacts ? "izinli" : "isteğe bağlı; gerekli değil")
        installButton.isEnabled = !installing && !checkingAPI && !app.busy && !(app.agent?.isRunning ?? false)
        installButton.title = installing ? "Kuruluyor…" : (status.py ? (online ? "Ses bağlantısı ortamını onar" : "Ortamı onar / modelleri sına") : "Ortamı kur (internet gerekir)")
        testButton.isEnabled = status.py && status.key && !app.busy && !installing && !checkingAPI
        testButton.title = checkingAPI ? "Bağlantı sınanıyor…" : "Seçili modellerin bağlantısını sına"
        finishButton.isEnabled = !installing && !app.busy
        finishButton.title = app.agent?.isRunning == true ? "Kapat" : "Asistan’ı başlat"
        if !checkingAPI, let checked = checkedSettings {
            let current = try? String(contentsOf: app.projectDir.appendingPathComponent(".env"), encoding: .utf8)
            if current != checked { invalidateAPICheck(); feedback.stringValue = "Ayarlar değişti. Bağlantıyı yeniden sınayın." }
        }
    }
    @objc func mobileSettings() { app.showMobileSettings() }
    @objc func modelSettings() { app.showModelSettings() }
    @objc func soundSettings() { app.showSoundPrefs() }
    @objc func revealApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    @objc func openPermissionSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func askPerms() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts); AVCaptureDevice.requestAccess(for: .audio) { _ in }
        CNContactStore().requestAccess(for: .contacts) { _, _ in }
    }
    @objc func checkAPI() {
        let status = app.setupStatus()
        guard status.py, status.key, !app.busy, !installing, !checkingAPI else { return }
        let settings = (try? String(contentsOf: app.projectDir.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
        let generation = UUID(); checkGeneration = generation; checkingAPI = true; checkedSettings = nil
        let process = Process(); process.executableURL = app.projectDir.appendingPathComponent(".venv/bin/python")
        process.arguments = ["-B", "-u", app.resDir.appendingPathComponent("agent.py").path, "--check-api"]
        process.environment = app.modelEnvironment(); process.currentDirectoryURL = app.projectDir
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        checkProcess = process; feedback.stringValue = "Seçili modeller küçük bir deneme isteğiyle sınanıyor…"; refresh()
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self = self, self.checkGeneration == generation, process.isRunning else { return }
                process.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
            DispatchQueue.global().async { [weak self] in
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self = self, self.checkGeneration == generation else { return }
                    self.checkingAPI = false; self.checkProcess = nil
                    let current = try? String(contentsOf: self.app.projectDir.appendingPathComponent(".env"), encoding: .utf8)
                    if current != settings { self.feedback.stringValue = "Ayarlar değişti; bağlantıyı yeniden sınayın."; self.refresh(); return }
                    if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let checks = result["checks"] as? [[String: Any]], !checks.isEmpty {
                        let message = checks.map { row in
                            ((row["ok"] as? Bool) == true ? "✓ " : "○ ") + (row["model"] as? String ?? "Model") + ": " + (row["message"] as? String ?? "Doğrulanamadı")
                        }.joined(separator: "\n")
                        self.checkedSettings = settings
                        self.feedback.stringValue = checks.allSatisfy({ $0["ok"] as? Bool == true }) ? "Seçili modellerin bağlantısı doğrulandı." : "Bağlantı testi başarısız; Kurulum ayrıntıları sekmesine bakın."
                        self.log(message + "\n")
                    } else { self.feedback.stringValue = "Bağlantı doğrulanamadı veya zaman aşımı. Model ayarlarını ve interneti kontrol edin." }
                    self.refresh()
                }
            }
        } catch { checkingAPI = false; checkProcess = nil; feedback.stringValue = "Bağlantı testi başlatılamadı."; refresh() }
    }
    @objc func runInstall() {
        guard !installing, !checkingAPI, !app.busy, !(app.agent?.isRunning ?? false) else { return }
        installing = true; refresh()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [app.resDir.appendingPathComponent("setup.sh").path, app.projectDir.path, app.resDir.path, (try? BetaModelConfiguration.voiceMode(in: app.savedSettings())) ?? "local"]
        var env = ProcessInfo.processInfo.environment; env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"; env["HOME"] = NSHomeDirectory(); process.environment = env
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.log(String(decoding: data, as: UTF8.self)) }
        }
        process.terminationHandler = { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }; self.installing = false
                self.feedback.stringValue = result.terminationStatus == 0 ? "Ortam kuruldu. Asistan’ı başlatabilirsiniz." : "Kurulum tamamlanamadı. Ayrıntılar sekmesine bakın."
                self.refresh()
            }
        }
        do { try process.run(); log("Kurulum başladı…\n"); feedback.stringValue = "İlerleme Kurulum ayrıntıları sekmesinde." }
        catch { installing = false; feedback.stringValue = "Kurulum başlatılamadı."; refresh() }
    }
    @objc func finish() {
        guard !installing, !app.busy else { return }
        if app.agent?.isRunning == true { window.close(); return }
        let status = app.setupStatus()
        guard status.audio && status.py && status.key && status.perms else { feedback.stringValue = "Eksik ortam, ses aygıtı, anahtar veya izni tamamlayın."; return }
        app.startAgentIfNeeded(); window.close()
    }
}

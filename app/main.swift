// Asistan — menü çubuğu uygulaması
// FaceTime/Telefon ve WhatsApp sesli aramalarını Loopback üzerinden karşılar.
// Ses aygıtları kalıcıdır; arama başında, sonunda veya devralmada değiştirilmez.

import Cocoa
import ApplicationServices
import AVFoundation
import CoreAudio
import UserNotifications
import Contacts
import ServiceManagement

var logHandle: FileHandle?
let logLock = NSLock()
func logLine(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(s)\n"
    if let d = line.data(using: .utf8) { logHandle?.write(d) }
}


// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var projectDir = AppMigration.dataDirectory(home: URL(fileURLWithPath: NSHomeDirectory()))  // kullanıcı verisi
    var resDir = Bundle.main.resourceURL ?? Bundle.main.bundleURL                                  // agent.py, setup.sh
    var setupController: SetupController?
    var statusItem: NSStatusItem!
    var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var autoItem: NSMenuItem!
    var lastNoteItem: NSMenuItem!
    var panel: NSPanel!
    var panelTitle: NSTextField!
    var answerButton: NSButton!


    var sessionID: String?
    var agentGeneration = UUID()
    var wasCallActive = false
    var connectionDeadline: Date?
    var sessionWatchdog: Date?
    var stoppingDeadline: Date?
    var agent: Process?
    var agentReady = false
    // Readiness of the loaded local engines persists while a call uses the agent.
    var localModelsReady = false
    var agentFailure: String?
    var preparationText = ""
    var inSession = false
    var busy = false           // asistanla cevaplanan bir arama sürüyor
    var answered = false       // bu bildirim için cevap verildi (kendimiz ya da kullanıcı)
    var dismissed = false      // kullanıcı paneli kapattı
    var missing = 0
    var liveWindow: NSWindow!
    var liveRows: [[String: Any]] = []
    var liveExtras: [(String, String, NSColor?)] = []
    var liveCallerHeading = ""
    var renderingLive = false
    var liveText: NSTextView!
    var showLive = (UserDefaults.standard.object(forKey: "showLive") as? Bool) ?? true
    var liveItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var noteField: NSTextField!
    var agentInput: FileHandle?
    var bannerTexts: [CallerLabel] = []
    var bannerSource: CallSource = .apple
    var sessionSource: CallSource?
    var humanCallActive = false
    let lineDecoder = AgentLineDecoder()
    let diagnosticDecoder = AgentLineDecoder()
    var lastNotePath: String?
    lazy var mobile = MobileBridge()
    var mobileSettings: MobileSettingsController?
    var mobileItem: NSMenuItem!
    var focusItem: NSMenuItem!
    var focusAuto = UserDefaults.standard.bool(forKey: "betaFocusAuto")
    let focusMonitor = FocusMonitor()
    var offerToken: String?
    var offerIdentity = ""
    var sessionCaller = ""
    var autoMode = UserDefaults.standard.bool(forKey: "autoMode")
    var paused = UserDefaults.standard.bool(forKey: "paused")
    var pauseItem: NSMenuItem!
    var lastPermissionState: String?
    var callFailure: (text: String, expires: Date)?
    var manualAnswer = false
    var modelSettings: ModelSettingsController?
    var personalization: PersonalizationController?
    var endItem: NSMenuItem!
    var takeItem: NSMenuItem!
    var endButton: NSButton!
    var takeButton: NSButton!
    var sendButton: NSButton!
    var liveStatus: NSTextField!
    var sessionStarted: Date?
    var sessionFinished: Date?
    var liveSource: CallSource?
    var usingLegacyData = false
    var statusSymbol = ""
    var liveFollow = true
    var quickNotePopup: NSPopUpButton!
    var recentMenu: NSMenu!
    var ringerName = ""
    var ringDiagnosticSaved = false
    var lastUnrecognizedWarning = Date.distantPast
    var settingsCache: (modified: Date?, values: [String: String])?
    let routeQueue = DispatchQueue(label: "com.mtahca.asistan.call-route")
    var routeFallback = (UserDefaults.standard.object(forKey: "routeFallbackDefaultInput") as? Bool) ?? true
    @objc func showPersonalization() {
        if personalization == nil { personalization = PersonalizationController(app: self) }
        personalization?.show()
    }
    @objc func restartFromMenu() {
        guard !busy else { notify("Görüşme sürüyor", "Görüşme bittikten sonra yeniden başlatabilirsiniz."); return }
        restartAgent()
    }
    @objc func showModelSettings() {
        if modelSettings == nil { modelSettings = ModelSettingsController(app: self) }
        modelSettings?.show()
    }
    @objc func togglePaused() { setPaused(!paused) }
    func setPaused(_ value: Bool) {
        paused = value; UserDefaults.standard.set(paused, forKey: "paused")
        pauseItem.state = paused ? .on : .off
        if paused { hidePanel() }
        updateStatus()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        resolveProjectDir()
        openLog()
        logLine("Uygulama başladı. Sürüm: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?"). Uygulama: \(Bundle.main.bundleURL.path). Klasör: \(projectDir.path)")
        if usingLegacyData {
            logLine("Asistan Beta açık; veriler taşınmadan eski klasörden kullanılıyor")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.notify("Asistan Beta hâlâ açık", "Aynı aramayı iki uygulama karşılamasın diye Beta’dan çıkıp Asistan’ı yeniden açın; veriler o zaman taşınır.")
            }
        }

        installDefaultListeners()
        if CallAudioRoute.restoreDefaultInput() { logLine("Önceki görüşmeden kalan sistem mikrofonu geri alındı") }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            logLine("Erişilebilirlik izni yok — Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik")
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in logLine("Mikrofon izni: \(ok)") }
        CNContactStore().requestAccess(for: .contacts) { ok, _ in logLine("Rehber izni: \(ok)") }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Asistan")
        applicationMenu.addItem(withTitle: "Kurulum ve izinleri kontrol et…", action: #selector(showSetup), keyEquivalent: ",").target = self
        applicationMenu.addItem(withTitle: "Ses ayarları…", action: #selector(showSoundPrefs), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: "Kişiselleştirme…", action: #selector(showPersonalization), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: "Modeller ve API anahtarları…", action: #selector(showModelSettings), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: "Ses ajanını yeniden başlat", action: #selector(restartFromMenu), keyEquivalent: "").target = self
        applicationMenu.addItem(NSMenuItem.separator())
        applicationMenu.addItem(withTitle: "Asistan’dan çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
        buildStatusItem()
        buildPanel()
        buildLiveWindow()
        mobile.onNote = { [weak self] text in _ = self?.deliverNote(text, fromPhone: true) }
        mobile.onEnd = { [weak self] in
            guard let self = self, self.inSession, self.stoppingDeadline == nil else { return }
            self.endSession()
        }
        mobile.onAnswer = { [weak self] in
            guard let self = self, self.offerToken != nil, !self.dismissed else { return }
            self.beginAnswer(manual: true)
        }
        mobile.onPause = { [weak self] on in self?.setPaused(on) }
        mobile.onChanged = { [weak self] in self?.refreshMobileMenu(); self?.mobileSettings?.refresh() }
        mobile.setQuickNotes(QuickNotes.load())
        mobile.startIfEnabled()
        if let notes = try? FileManager.default.contentsOfDirectory(at: projectDir.appendingPathComponent("notlar"), includingPropertiesForKeys: nil) {
            lastNotePath = notes.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last?.path
        }
        publishHistory(fresh: false)
        let st = setupStatus()
        if st.audio && st.py && st.key { startAgent() } else { showSetup() }
        CallObserver.shared.start()
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        updateStatus()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if !st.perms || UserDefaults.standard.string(forKey: "setupSeenVersion") != version {
            UserDefaults.standard.set(version, forKey: "setupSeenVersion")
            showSetup()
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        CallAudioRoute.restoreDefaultInput()  // not on routeQueue: it may be waiting for the main thread
        mobile.shutdown()
        setupController?.stopAPICheck()
        sendCommand(["command": "shutdown"])
        agent?.terminate()
    }


    func resolveProjectDir() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let betaRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: AppMigration.legacyBundleID).isEmpty
        projectDir = AppMigration.resolveDataDirectory(home: home, legacyRunning: betaRunning)
        usingLegacyData = projectDir.path == AppMigration.legacyDataDirectory(home: home).path
        resDir = Bundle.main.resourceURL ?? Bundle.main.bundleURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Kurulum durumu: (Loopback, Python ortamı, API anahtarı, izinler)
    func setupStatus() -> (audio: Bool, py: Bool, key: Bool, perms: Bool) {
        let audio = loopbackAudioReady()
        let fm = FileManager.default
        let pyExe = fm.isExecutableFile(atPath: projectDir.appendingPathComponent(".venv/bin/python").path)
        let mode = (try? BetaModelConfiguration.voiceMode(in: savedSettings())) ?? "local"
        let marker = fm.fileExists(atPath: projectDir.appendingPathComponent(".deps_ok").path) || (mode == "gpt-live" && fm.fileExists(atPath: projectDir.appendingPathComponent(".deps_ok_online").path))
        let py = pyExe && marker
        let values = savedSettings()
        let key = (try? BetaModelConfiguration.missingCredentials(in: values).isEmpty) ?? false
        let perms = AXIsProcessTrusted()
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        return (audio, py, key, perms)
    }

    /// Read every 0.4 s by the status tick; re-parse only when the file changes.
    func savedSettings() -> [String: String] {
        let url = projectDir.appendingPathComponent(".env")
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cache = settingsCache, cache.modified == modified { return cache.values }
        let values = BetaModelConfiguration.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        settingsCache = (modified, values)
        return values
    }
    func modelEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let values = savedSettings()
        for (key, fallback) in [("VOICE_MODE", "local"), ("LLM_PROVIDER", "anthropic"), ("CLAUDE_MODEL", "claude-haiku-4-5"),
                                ("OPENAI_MODEL", "gpt-6-luna"), ("SUMMARY_PROVIDER", ""), ("SUMMARY_MODEL", "")] {
            env[key] = values[key] ?? fallback
        }
        env["ASISTAN_HOME"] = projectDir.path
        return env
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup(); return true
    }
    func startAgentIfNeeded() {
        if agent == nil || !(agent?.isRunning ?? false) { startAgent() }
        updateStatus()
    }

    @objc func showSetup() {
        if setupController == nil { setupController = SetupController(app: self) }
        setupController?.show()
    }

    func openLog() {
        let path = projectDir.appendingPathComponent("app.log").path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            let previous = path + ".previous"
            try? FileManager.default.removeItem(atPath: previous)
            try? FileManager.default.moveItem(atPath: path, toPath: previous)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous)
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        logHandle = FileHandle(forWritingAtPath: path)
        logHandle?.seekToEndOfFile()
    }

    // MARK: Menü çubuğu

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            if let img = NSImage(systemSymbolName: "phone.circle", accessibilityDescription: "Asistan") {
                b.image = img
            } else {
                b.title = "☎︎"
            }
        }
        let menu = NSMenu(); menu.autoenablesItems = false
        statusLine.isEnabled = false; menu.addItem(statusLine); menu.addItem(.separator())
        func item(_ title: String, _ action: Selector, _ targetMenu: NSMenu = menu, key: String = "") -> NSMenuItem {
            let view = NSMenuItem(title: title, action: action, keyEquivalent: key)
            view.target = self; targetMenu.addItem(view); return view
        }
        pauseItem = item("Arama karşılamayı duraklat", #selector(togglePaused), key: "p")
        pauseItem.state = paused ? .on : .off
        autoItem = item("Gelen aramayı otomatik cevapla", #selector(toggleAuto))
        autoItem.state = autoMode ? .on : .off
        focusItem = item("Odak açıkken otomatik cevapla", #selector(toggleFocusAuto))
        focusItem.state = focusAuto ? .on : .off
        mobileItem = item("iPhone ve Odak…", #selector(showMobileSettings))
        refreshMobileMenu()
        menu.addItem(.separator())
        _ = item("Canlı görüşmeyi aç", #selector(openLiveWindow))
        takeItem = item("Görüşmeyi devral", #selector(takeOver), key: "d")
        endItem = item("Aramayı sonlandır", #selector(endSession), key: "e")
        lastNoteItem = item("Son notu aç", #selector(openLastNote)); lastNoteItem.isEnabled = false
        let recentItem = NSMenuItem(title: "Son görüşmeler", action: nil, keyEquivalent: "")
        recentMenu = NSMenu(); recentMenu.autoenablesItems = false; recentMenu.delegate = self
        recentItem.submenu = recentMenu; menu.addItem(recentItem)
        _ = item("Notlar klasörünü aç", #selector(openNotesFolder))
        menu.addItem(.separator())
        _ = item("Kişiselleştirme…", #selector(showPersonalization))
        _ = item("Ses ayarları…", #selector(showSoundPrefs))
        _ = item("Modeller ve API anahtarları…", #selector(showModelSettings))
        _ = item("Kurulum ve izinleri kontrol et…", #selector(showSetup))
        let advancedItem = NSMenuItem(title: "Diğer seçenekler", action: nil, keyEquivalent: "")
        let advanced = NSMenu(); advanced.autoenablesItems = false
        liveItem = item("Görüşme sırasında canlı metni göster", #selector(toggleLive), advanced)
        liveItem.state = showLive ? .on : .off
        loginItem = item("Oturum açılışında başlat", #selector(toggleLogin), advanced)
        refreshLoginItem()
        _ = item("Ses ajanını yeniden başlat", #selector(restartFromMenu), advanced)
        _ = item("Tanı bilgilerini kaydet (5 sn sonra)", #selector(dumpDiag), advanced)
        _ = item("Kayıt dosyasını aç", #selector(openLogFile), advanced)
        advancedItem.submenu = advanced; menu.addItem(advancedItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Asistan’dan çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func updateStatus() {
        let accessibility = AXIsProcessTrusted()
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let permissionState = "Erişilebilirlik=\(accessibility), Mikrofon=\(microphone)"
        if permissionState != lastPermissionState {
            logLine("Güncel izinler: \(permissionState)")
            lastPermissionState = permissionState
        }
        let text: String
        if agent == nil || !(agent?.isRunning ?? false) {
            let setup = setupStatus()
            if let failure = agentFailure { text = "Asistan hazırlanamadı: " + failure }
            else if !setup.py { text = "Yerel konuşma ortamının kurulumu gerekiyor" }
            else if !setup.key { text = "Seçili modellerin API ayarları eksik" }
            else if !setup.audio { text = "Loopback ses aygıtları eksik" }
            else { text = "Asistan çalışmıyor — yeniden başlatılabilir" }
        }
        else if humanCallActive { text = "Görüşmeyi siz devraldınız" }
        else if inSession { text = "Asistan görüşmede" + (sessionCaller.isEmpty || sessionCaller == "Bilinmiyor" ? "" : " · " + sessionCaller) }
        else if busy { text = "Arama bağlantısı doğrulanıyor…" }
        else if paused { text = "Duraklatıldı — arama karşılanmıyor" }
        else if !accessibility { text = "Erişilebilirlik izni kullanılamıyor" }
        else if !microphone { text = "Mikrofon izni bekleniyor" }
        else if let failure = callFailure, Date() < failure.expires { text = failure.text }
        else if !loopbackAudioReady() { text = "Loopback ses aygıtları hazır değil" }
        else if !agentReady { text = "Asistan hazırlanıyor…" }
        else if FocusPolicy.shouldAnswer(manualAuto: autoMode, focusAuto: focusAuto, focused: focusMonitor.active, paused: paused) {
            text = autoMode ? "Asistan hazır · otomatik cevaplama açık" : "Asistan hazır · Odak için otomatik cevaplama açık"
        }
        else { text = "Asistan hazır" }
        statusLine.title = text
        statusItem.button?.toolTip = text
        let symbol = inSession || humanCallActive || busy ? "phone.circle.fill"
            : (paused ? "pause.circle" : (agent?.isRunning != true || agentFailure != nil || !accessibility || !microphone ? "exclamationmark.circle" : "phone.circle"))
        if symbol != statusSymbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Asistan") {
            image.isTemplate = true; statusItem.button?.image = image; statusSymbol = symbol
        }
        var callTitle = ""
        lastNoteItem.isEnabled = lastNotePath != nil
        let active = busy && sessionID != nil && stoppingDeadline == nil
        endItem.isEnabled = active; endButton.isEnabled = active
        takeItem.isEnabled = active && inSession; takeButton.isEnabled = active && inSession
        sendButton.isEnabled = active && inSession; noteField.isEnabled = active && inSession
        if let started = sessionStarted {
            if !busy && sessionFinished == nil { sessionFinished = Date() }
            let seconds = max(0, Int((sessionFinished ?? Date()).timeIntervalSince(started)))
            let source = liveSource == .whatsapp ? "WhatsApp" : "Telefon / FaceTime"
            let clock = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            liveStatus.stringValue = source + " · " + clock + " · " + (busy ? (humanCallActive ? "Siz görüşmedesiniz" : "Asistan görüşmede") : "Görüşme bitti")
            if inSession || humanCallActive { callTitle = " " + clock }
        }
        statusItem.button?.title = callTitle
        if panel.isVisible {
            answerButton.isEnabled = agentReady && !busy && !paused && accessibility && microphone && loopbackAudioReady()
            panelTitle.stringValue = !accessibility ? "Erişilebilirlik izni gerekli" : (!microphone ? "Mikrofon izni gerekli" : (!agentReady ? "Asistan hazırlanıyor…" : "Gelen arama" + (ringerName.isEmpty ? "" : " · " + ringerName)))
        }
        publishMobileState()
    }

    func refreshMobileMenu() {
        guard mobileItem != nil else { return }
        mobileItem.state = mobile.enabled ? .on : .off
        mobileItem.title = "iPhone ve Odak…" + (mobile.clientCount > 0 ? " (\(mobile.clientCount) cihaz)" : "")
    }
    @objc func showMobileSettings() {
        if mobileSettings == nil { mobileSettings = MobileSettingsController(app: self) }
        mobileSettings?.show()
    }
    func setFocusAuto(_ enabled: Bool) {
        focusAuto = enabled; UserDefaults.standard.set(enabled, forKey: "betaFocusAuto")
        focusItem?.state = enabled ? .on : .off
        focusMonitor.refresh(enabled: enabled, force: true); updateStatus()
    }
    @objc func toggleFocusAuto() {
        setFocusAuto(!focusAuto)
        if focusAuto && focusMonitor.active == nil { showMobileSettings() }
    }
    func publishMobileState() {
        let r = scanNotifications()
        let ringing = r.button != nil && !busy && !answered && !dismissed && !paused && agentReady && setupStatus().perms && loopbackAudioReady() && callControl(for: .apple) == nil && callControl(for: .whatsapp) == nil
        let info = ringing ? extractCaller(from: r.texts, source: r.source) : CallerInfo()
        let ringer = !info.name.isEmpty ? info.name : (!info.number.isEmpty ? info.number : "Bilinmeyen arayan")
        ringerName = ringing && ringer != "Bilinmeyen arayan" ? ringer : ""
        let identity = ringing ? r.source.rawValue + "|" + ringer : ""
        if !ringing { offerToken = nil; offerIdentity = "" }
        else if offerToken == nil || offerIdentity != identity { offerToken = UUID().uuidString; offerIdentity = identity }
        mobile.setState(inSession: inSession && stoppingDeadline == nil, caller: sessionCaller,
                        startedAt: sessionStarted, status: statusLine.title, ringing: ringing, ringer: ringing ? ringer : "",
                        context: inSession ? sessionID : offerToken, paused: paused, stopping: stoppingDeadline != nil,
                        source: (inSession || humanCallActive ? liveSource : (ringing ? r.source : nil)).map { $0 == .whatsapp ? "whatsapp" : "phone" } ?? "",
                        humanCall: humanCallActive)
    }
    @objc func toggleAuto() {
        autoMode.toggle()
        UserDefaults.standard.set(autoMode, forKey: "autoMode")
        autoItem.state = autoMode ? .on : .off
        updateStatus()
    }
    /// Metin dosyalarını Xcode yerine TextEdit ile açar
    func openInTextEdit(_ url: URL) {
        if let te = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: te, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func openLastNote() { if let p = lastNotePath { openInTextEdit(URL(fileURLWithPath: p)) } }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let notes = RecentNotes.list(in: projectDir.appendingPathComponent("notlar"))
        if notes.isEmpty {
            let empty = NSMenuItem(title: "Henüz görüşme notu yok", action: nil, keyEquivalent: ""); empty.isEnabled = false
            menu.addItem(empty); return
        }
        for note in notes {
            let entry = NSMenuItem(title: note.title, action: #selector(openRecentNote(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = note.url; menu.addItem(entry)
        }
    }
    @objc func openRecentNote(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { openInTextEdit(url) } }
    @objc func openNotesFolder() { NSWorkspace.shared.open(projectDir.appendingPathComponent("notlar")) }
    @objc func openLogFile() { openInTextEdit(projectDir.appendingPathComponent("app.log")) }
    @objc func restartAgent() {
        agentGeneration = UUID()
        sendCommand(["command": "shutdown"])
        let previous = agent
        previous?.terminate()
        agent = nil
        agentInput = nil
        agentReady = false
        localModelsReady = false
        inSession = false
        busy = false
        sessionID = nil; sessionSource = nil; humanCallActive = false
        releaseCallRoute()
        connectionDeadline = nil
        stoppingDeadline = nil
        sessionWatchdog = nil
        DispatchQueue.global().async { [weak self] in
            if let previous = previous {
                let deadline = Date().addingTimeInterval(3)
                while previous.isRunning && Date() < deadline { usleep(100_000) }
                if previous.isRunning { kill(previous.processIdentifier, SIGKILL) }
                previous.waitUntilExit()
            }
            DispatchQueue.main.async { self?.startAgent() }
        }
    }



    /// Görüşmeyi devral: asistan susar; fiziksel mikrofon sabit Loopback hattına aktarılır.
    var tookOver = false
    var callGoneTicks = 0

    /// Oturumu sonlandır ve yalnızca bu oturumun aramasını kapat.
    @objc func endSession() {
        guard busy, stoppingDeadline == nil, let sid = sessionID else { appendLiveNote("Etkin asistan görüşmesi yok."); return }
        sendCommand(["command": humanCallActive ? "stop_bridge" : "end", "session_id": sid])
        stoppingDeadline = Date().addingTimeInterval(2)
        if let button = sessionSource.flatMap({ callControl(for: $0) }) {
            let ok = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            if !ok { notify("Arama kapatılamadı", "arama uygulamasından aramayı elle kapatabilirsiniz.") }
        } else { notify("Asistan durduruluyor", "Aramayı kapatma düğmesine ulaşılamadı. arama uygulamasından kapatabilirsiniz.") }
    }

    /// Kaynağa ait görüşme kontrolü kaybolduğunda ses oturumunu durdur.
    func detectCallEnded(incoming: Bool) {
        guard (inSession || humanCallActive), let sid = sessionID else { callGoneTicks = 0; return }
        if sessionSource.flatMap({ callControl(for: $0) }) != nil { wasCallActive = true; callGoneTicks = 0; return }
        guard wasCallActive, !incoming else { return }
        callGoneTicks += 1
        if callGoneTicks == 10 {
            sendCommand(["command": humanCallActive ? "stop_bridge" : "disconnected", "session_id": sid])
            stoppingDeadline = Date().addingTimeInterval(2)
        }
    }
    @objc func takeOver() {
        guard inSession, let sid = sessionID else { appendLiveNote("Etkin asistan görüşmesi yok."); return }
        tookOver = true
        sendCommand(["command": "takeover", "session_id": sid])
        stoppingDeadline = Date().addingTimeInterval(4)
        appendLiveNote("— Görüşmeyi devralıyorsunuz; mikrofonunuz aynı hatta bağlanıyor —")
    }

    func refreshLoginItem() {
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isEnabled = false
        }
    }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logLine("Oturum açılışı ayarı değişmedi: \(error)")
            notify("Oturum açılışı ayarlanamadı", "\(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            notify("Onay gerekiyor", "Sistem Ayarları > Genel > Oturum Açma Öğeleri'nden Asistan’a izin ver.")
        }
        refreshLoginItem()
    }

    var soundPrefs: SoundPrefsController?
    func humanMicrophoneName() -> String {
        let uid = UserDefaults.standard.string(forKey: "humanMicrophoneUID") ?? ""
        if !uid.isEmpty {
            // An unplugged choice must not silently record a different microphone.
            guard let device = deviceID(forUID: uid), hasStreams(device, input: true),
                  transportType(device) != kAudioDeviceTransportTypeVirtual else { return "" }
            return deviceName(device)
        }
        return builtinDevice(input: true).map(deviceName) ?? ""
    }
    @objc func showSoundPrefs() {
        if soundPrefs == nil { soundPrefs = SoundPrefsController(app: self) }
        soundPrefs?.show()
    }

    @objc func dumpDiag() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            let u = self.projectDir.appendingPathComponent("tani.txt")
            logLine("Tanı: ses kullanan süreçler: \(audioProcessReport())")
            dumpTree(bundleIDs: ["com.apple.notificationcenterui"] + CallSource.apple.bundleIDs + CallSource.whatsapp.bundleIDs, to: u)
            var menus = "\n== Arama uygulamalarının menüleri\n"
            for target in CallAudioRoute.apps {
                let outline = CallAudioRoute.describeMenus(bundleID: target.bundleID)
                if !outline.isEmpty { menus += "\n-- \(target.name) (\(target.bundleID))\n" + outline }
            }
            menus += "\nAsistan Mikrofonu’nu kullanan: " + (CallAudioRoute.microphoneUsers().map { $0.isEmpty ? "kimse" : $0.joined(separator: ", ") } ?? "macOS bildirmedi") + "\n"
            if let handle = try? FileHandle(forWritingTo: u) { handle.seekToEndOfFile(); handle.write(Data(menus.utf8)); try? handle.close() }
            logLine("Tanı yazıldı: \(u.path)")
        }
    }

    @objc func toggleLive() {
        showLive.toggle()
        UserDefaults.standard.set(showLive, forKey: "showLive")
        liveItem.state = showLive ? .on : .off
    }
    @objc func openLiveWindow() { liveWindow.orderFrontRegardless() }

    /// Ajan çıktısındaki satırı ("[13:58:08] ARAYAN: ...") canlı pencereye yansıtır


    // MARK: Arama izleme

    func tick() {
        focusMonitor.refresh(enabled: focusAuto)
        if let deadline = stoppingDeadline, Date() >= deadline {
            stoppingDeadline = nil
            appendLiveNote("Ses ajanı zamanında durmadı; güvenli yeniden başlatma yapılıyor.")
            restartAgent()
            return
        }
        if let deadline = sessionWatchdog, Date() >= deadline {
            endSession(); sessionWatchdog = nil
        }
        if paused && !busy { hidePanel(); updateStatus(); return }
        if (inSession || humanCallActive), !loopbackAudioReady(), let sid = sessionID {
            sendCommand(["command": humanCallActive ? "stop_bridge" : "route_lost", "session_id": sid])
            if stoppingDeadline == nil { stoppingDeadline = Date().addingTimeInterval(2) }
        }
        let r = scanNotifications()
        let incoming = r.button != nil
        missing = incoming ? 0 : missing + 1
        if let deadline = connectionDeadline {
            if sessionSource.flatMap({ callControl(for: $0) }) != nil {
                wasCallActive = true
                connectionDeadline = nil
                CallObserver.shared.urgent = false
                startConfirmedSession()
            } else if Date() >= deadline {
                connectionDeadline = nil
                abortPendingCall("Arama bağlantısı doğrulanamadı. arama uygulamasından devralabilirsiniz.")
            }
        }
        detectCallEnded(incoming: incoming)
        if incoming && !busy {
            bannerTexts = r.texts; bannerSource = r.source
            saveRingDiagnosticIfUnknown(r)
        }
        if incoming && !answered && !dismissed && !busy {
            showPanel()
            if FocusPolicy.shouldAnswer(manualAuto: autoMode, focusAuto: focusAuto, focused: focusMonitor.active, paused: paused), agentReady, setupStatus().perms, loopbackAudioReady(), callControl(for: .apple) == nil, callControl(for: .whatsapp) == nil { beginAnswer(manual: false) }
        }
        if !busy, let unknown = CallObserver.shared.unrecognized(), Date().timeIntervalSince(lastUnrecognizedWarning) > 120 {
            lastUnrecognizedWarning = Date()
            writeRingDiagnostic(unknown, heading: "Cevaplama düğmesi bulunamadı")
            callFailure = ("Gelen arama tanınamadı; aramayı elle cevaplayın", Date().addingTimeInterval(60))
            notify("Gelen arama tanınamadı", "\(unknown.source.rawValue) aramasında cevaplama düğmesi beklenen adla bulunamadı; uygulama güncellenmiş olabilir. Aramayı elle cevaplayın. Ayrıntılar son_arama_tani.txt dosyasında.")
        }
        if missing >= 2 { hidePanel() }
        if missing > 5 && !busy { answered = false; dismissed = false; bannerTexts = []; ringDiagnosticSaved = false }
        updateStatus()
    }

    /// When the ringing banner yields no caller, keep its raw accessibility labels once per ring so
    /// the extraction rules can be fixed from real data. Local file only; overwritten each time.
    func saveRingDiagnosticIfUnknown(_ result: ScanResult) {
        guard !ringDiagnosticSaved else { return }
        let info = extractCaller(from: result.texts, source: result.source)
        guard info.name.isEmpty && info.number.isEmpty else { return }
        ringDiagnosticSaved = true
        writeRingDiagnostic(result, heading: "Arayan bulunamadı")
    }
    /// The banner's raw accessibility labels, kept so matching rules can be fixed from real data.
    func writeRingDiagnostic(_ result: ScanResult, heading: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var out = "\(heading) — \(Date())\nSürüm: \(version) · Derleme \(build)\nKaynak: \(result.source.rawValue)\n\n"
        for label in result.texts { out += "\(label.role) \(label.attribute): \(label.value.replacingOccurrences(of: "\n", with: "⏎"))\n" }
        let url = projectDir.appendingPathComponent("son_arama_tani.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        logLine("\(heading); bildirim yapısı kaydedildi: \(url.lastPathComponent)")
    }

    /// Bildirimdeki "cevapla" düğmesine basar
    func pressAnswer(_ result: ScanResult) -> Bool {
        guard let button = result.button else { return false }
        let error = AXUIElementPerformAction(button, result.action as CFString)
        logLine("Cevaplama eylemi: \(result.action), sonuç=\(error.rawValue)")
        return error == .success
    }

    @objc func answerWithAssistant() { beginAnswer(manual: true) }

    func beginAnswer(manual: Bool) {
        logLine("Cevaplama istendi. elle=\(manual), ajan=\(agentReady), meşgul=\(busy), duraklatıldı=\(paused)")
        if busy { return }
        manualAnswer = manual
        guard agentReady, !paused, setupStatus().perms else {
            reportCallFailure(!agentReady ? "Ses modelleri henüz hazır değil." : (paused ? "Arama karşılama duraklatılmış." : "Asistan gerekli izinleri kullanamıyor.")); return
        }
        let incoming = scanNotifications()
        guard incoming.button != nil else { reportCallFailure("Gelen aramanın cevaplama düğmesine şu anda ulaşılamıyor."); return }
        guard loopbackAudioReady() else { reportCallFailure("Loopback’te Asistan Dinleme, Asistan Ses Çıkışı ve Asistan Mikrofonu aygıtlarını açık tutun."); return }
        guard callControl(for: .apple) == nil, callControl(for: .whatsapp) == nil else {
            reportCallFailure("Başka bir görüşme açık. Aynı anda bir görüşme karşılanabilir."); return
        }
        callFailure = nil
        sessionSource = incoming.source
        sessionID = UUID().uuidString.lowercased()
        busy = true; answered = true; tookOver = false; wasCallActive = false; callGoneTicks = 0
        bannerTexts = incoming.texts
        sessionCaller = ""
        hidePanel(); updateStatus()
        let sid = sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.busy, self.sessionID == sid else { return }
            if self.pressAnswer(incoming) {
                self.connectionDeadline = Date().addingTimeInterval(8); logLine("Aramanın bağlanması bekleniyor")
                CallObserver.shared.urgent = true
                self.sendCommand(["command": "prewarm"])  // GPT-Live session opens while the call connects
            }
            else { self.abortPendingCall("Arama artık çalmıyor veya cevaplama düğmesine ulaşılamadı.") }
        }
    }

    // MARK: Python ajanı

    func startAgent() {
        guard agent == nil || !(agent?.isRunning ?? false) else { return }
        let py = projectDir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: py.path) else { updateStatus(); return }
        agentFailure = nil; localModelsReady = false; preparationText = "Ses ajanı başlatılıyor"
        let generation = UUID(); agentGeneration = generation; lineDecoder.reset(); diagnosticDecoder.reset()
        let p = Process(); p.executableURL = py
        p.arguments = ["-B", "-u", resDir.appendingPathComponent("agent.py").path]
        p.currentDirectoryURL = projectDir
        var env = modelEnvironment()
        env["ASISTAN_HOME"] = projectDir.path; env["PYTHONUNBUFFERED"] = "1"
        env["BETA_AUDIO_INPUT"] = BetaAudio.listenName
        env["BETA_AUDIO_OUTPUT"] = BetaAudio.playbackName
        env["BETA_HUMAN_MIC"] = builtinDevice(input: true).map(deviceName) ?? ""
        p.environment = env
        let input = Pipe(); p.standardInput = input; agentInput = input.fileHandleForWriting
        let pipe = Pipe(); p.standardOutput = pipe
        let diagnostics = Pipe(); p.standardError = diagnostics
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self = self, self.agentGeneration == generation else { return }
                for line in self.diagnosticDecoder.append(bytes) { logLine("agent: " + line) }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self = self, self.agentGeneration == generation else { return }
                self.consume(data)
            }
        }
        p.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self, self.agentGeneration == generation else { return }
                logLine("Ses ajanı çıktı: kod=\(process.terminationStatus), neden=\(process.terminationReason == .uncaughtSignal ? "sinyal" : "normal çıkış")")
                if self.agentFailure == nil { self.agentFailure = "Ses ajanı kapandı (kod \(process.terminationStatus))." }
                self.agent = nil; self.agentInput = nil; self.agentReady = false; self.localModelsReady = false
                self.inSession = false; self.busy = false; self.sessionID = nil; self.sessionSource = nil; self.humanCallActive = false
                self.connectionDeadline = nil; self.stoppingDeadline = nil; self.sessionWatchdog = nil
                self.releaseCallRoute()
                self.updateStatus()
                self.notify("Asistan ses ajanı durdu", "Kurulum veya izinleri kontrol edip yeniden başlatabilirsiniz.")
            }
        }
        do { try p.run(); agent = p; agentReady = false }
        catch {
            agentFailure = error.localizedDescription
            logLine("Ses ajanı başlatılamadı: " + error.localizedDescription)
            notify("Asistan başlatılamadı", error.localizedDescription)
        }
        updateStatus()
    }

    func consume(_ bytes: Data) {
        for line in lineDecoder.append(bytes) { handleLine(line) }
    }

    func handleLine(_ line: String) {
        guard let event = AgentLineDecoder.event(line), let kind = event["event"] as? String else {
            logLine("agent: " + line); return
        }
        let sid = event["session_id"] as? String
        let text = event["text"] as? String ?? ""
        if kind == "loading" { preparationText = text; logLine("Hazırlık: " + text); return }
        if kind == "ready" { localModelsReady = true; if !busy { agentReady = true }; logLine("Ses motoru hazır"); updateStatus(); return }
        if kind == "fatal" {
            agentFailure = text; logLine("Ses ajanı hazırlık hatası: " + text)
            appendLiveNote("Asistan hazırlanamadı: " + text)
            notify("Asistan hazırlanamadı", text); agentReady = false; localModelsReady = false; updateStatus(); return
        }
        if kind == "summary_saved" || kind == "summary_failed" {
            if let path = event["path"] as? String, validNotePath(path) {
                if !busy && (lastNotePath == nil || lastNotePath == path) { lastNotePath = path }
                notify(kind == "summary_saved" ? "Arama özeti hazır" : "Döküm kaydedildi; özet hazırlanamadı", (path as NSString).lastPathComponent)
                publishHistory(fresh: kind == "summary_saved")
            }
            updateStatus(); return
        }
        guard sid == sessionID, sid != nil else { return }
        switch kind {
        case "bridge_ended":
            humanCallActive = false; busy = false; inSession = false; agentReady = true
            sessionID = nil; sessionSource = nil; stoppingDeadline = nil; sessionWatchdog = nil
            releaseCallRoute()
            appendLiveNote("— Devralınan görüşmenin ses hattı kapandı —")
        case "session_started":
            logLine("Asistan görüşmesi başladı; kaynak=\(sessionSource?.rawValue ?? "Bilinmiyor"), ses=\(event["voice_mode"] as? String ?? "local")")
            inSession = true; agentReady = false
            stoppingDeadline = nil; sessionWatchdog = Date().addingTimeInterval(310)
            sessionStarted = Date(); sessionFinished = nil; liveSource = sessionSource
            noteField.stringValue = ""
            liveRows = []; liveExtras = []; liveCallerHeading = ""
            mobile.reset(); sessionCaller = "Bilinmiyor"
            liveText.string = ""; liveFollow = true; if showLive { liveWindow.orderFrontRegardless() }
            if let caller = event["caller"] as? [String: Any] {
                let parts = [caller["name"] as? String ?? "", caller["number"] as? String ?? ""].filter { !$0.isEmpty }
                sessionCaller = parts.isEmpty ? "Bilinmiyor" : parts.joined(separator: " ")
                liveCallerHeading = "Arayan: " + sessionCaller
                appendLiveNote(liveCallerHeading)
            }
        case "live_status": logLine("GPT-Live: " + text)
        case "live_notice": logLine("GPT-Live: " + text); appendLiveNote(text)
        case "live_transcript":
            if let rows = event["rows"] as? [[String: Any]] {
                liveRows = rows
                renderLiveTranscript()
            }
        case "live_usage":
            if let seconds = event["seconds"] as? Double {
                appendLiveNote(String(format: "GPT-Live: %.0f sn · ses oturumu yaklaşık $%.3f (arka plan/özet hariç)%@", seconds, seconds / 60 * 0.05, (event["finalized"] as? Bool == true) ? "" : " · son kullanım doğrulanamadı"))
            }
        case "transcript": appendLive(event["speaker"] as? String ?? "", text, color: (event["speaker"] as? String) == "Arayan" ? .systemBlue : .systemGreen)
        case "interrupted": appendLiveNote("Arayan araya girdi; asistan sustu.")
        case "note_status": appendLive("Not durumu", text + " — " + (event["status"] as? String ?? ""), color: .systemPurple)
        case "error": appendLiveNote(text); logLine("Görüşme hatası: \(text)")
        case "metrics":
            if let duration = event["first_audio_s"] as? Double { logLine(String(format: "İlk yanıt sesi: %.2f sn", duration)) }
        case "session_ended":
            let reason = event["reason"] as? String ?? "error"
            logLine("Asistan görüşmesi bitti: \(reason)")
            humanCallActive = reason == "takeover" && (event["bridge_active"] as? Bool == true)
            inSession = false; busy = humanCallActive; agentReady = !humanCallActive
            connectionDeadline = nil; sessionWatchdog = nil; stoppingDeadline = nil
            if let path = event["path"] as? String, validNotePath(path) { lastNotePath = path }
                if reason == "route_lost" { notify("Ses hattı değişti", "Asistan konuşmayı durdurdu; aramayı arama uygulamasından devralabilirsiniz.") }
            if reason == "takeover" || tookOver { tookOver = false }
            else if ["completed", "silence", "time_limit"].contains(reason) {
                if let button = sessionSource.flatMap({ callControl(for: $0) }) {
                    if AXUIElementPerformAction(button, kAXPressAction as CFString) != .success { notify("Arama açık kalmış olabilir", "arama uygulamasından aramayı kapatabilirsiniz.") }
                } else { notify("Asistan oturumu tamamlandı", "Arama kapatma düğmesine ulaşılamadı; arama uygulamasından kontrol edin.") }
            }
            let saved = event["saved"] as? Bool ?? false
            if reason == "takeover" {
                appendLiveNote(humanCallActive ? "— Görüşmeyi devraldınız; mikrofonunuz aynı hatta aktarılıyor —" : "— Devralma mikrofonu açılamadı; arama uygulamasından devralabilirsiniz —")
                if !humanCallActive { notify("Devralma sesi başlamadı", "Arama uygulamasından mikrofonunuzu seçebilirsiniz.") }
            } else { appendLiveNote(saved ? "— Asistan oturumu bitti; döküm kaydedildi —" : "— Asistan durdu; döküm kaydedilemedi —") }
            if !humanCallActive { sessionID = nil; sessionSource = nil; releaseCallRoute() }
        default: break
        }
        updateStatus()
    }


    @discardableResult func sendCommand(_ command: [String: Any]) -> Bool {
        guard let handle = agentInput, let data = try? JSONSerialization.data(withJSONObject: command) else { return false }
        do { try handle.write(contentsOf: data + Data([10])); return true }
        catch { logLine("Ajan komutu iletilemedi"); return false }
    }
    func publishHistory(fresh: Bool) {
        mobile.setHistory(RecentNotes.historyItems(in: projectDir.appendingPathComponent("notlar")), fresh: fresh)
    }
    func quickNotesChanged() {
        mobile.setQuickNotes(QuickNotes.load()); rebuildQuickNotes()
    }
    func validNotePath(_ path: String) -> Bool {
        RecentNotes.isNote(path: path, in: projectDir.appendingPathComponent("notlar"))
    }
    func startConfirmedSession() {
        guard busy, let sid = sessionID else { return }
        logLine("Arama bağlantısı doğrulandı; ses ajanı başlatılıyor")
        let source = sessionSource ?? bannerSource
        let incomingCaller = extractCaller(from: bannerTexts, source: source)
        let caller = enrichFromContacts(callerAfterConnection(incoming: incomingCaller, connected: CallObserver.shared.connectedCaller(source)))
        if !sendCommand(["command": "begin", "session_id": sid, "caller": ["name": caller.name, "number": caller.number, "in_contacts": caller.inContacts], "microphone": humanMicrophoneName()]) {
            abortPendingCall("Ses ajanına ulaşılamadı."); return
        }
        sessionWatchdog = Date().addingTimeInterval(310)
        secureCallRoute(sid: sid, source: source)
        // Starting the session must itself have an acknowledgement.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.sessionID == sid, self.busy, !self.inSession else { return }
            self.restartAgent()
            self.notify("Asistan oturumu başlamadı", "Aramayı arama uygulamasından devralabilirsiniz.")
        }
    }
    /// After the call connects: make the call app use Asistan Mikrofonu and confirm that it records from it.
    /// The menu choice is retried because a call app launched by the call needs a few seconds to build its menus.
    func secureCallRoute(sid: String, source: CallSource) {
        let apps = CallAudioRoute.apps.filter { source.bundleIDs.contains($0.bundleID) }
        let fallback = routeFallback
        let preferred = getDefault(kAudioHardwarePropertyDefaultOutputDevice).map(deviceName)
        routeQueue.async { [weak self] in
            func current() -> Bool { DispatchQueue.main.sync { self?.sessionID == sid && self?.busy == true } }
            var switched = false
            for attempt in 1...6 {
                guard current() else { return }
                let reports = apps.map { CallAudioRoute.check(bundleID: $0.bundleID, name: $0.name, apply: true, preferredOutput: preferred) }
                usleep(1_000_000)
                let users = CallAudioRoute.microphoneUsers()
                let summary = reports.map { $0.summary }.joined(separator: "; ")
                let usage = users.map { $0.isEmpty ? "kimse" : $0.joined(separator: ", ") } ?? "macOS bildirmedi"
                DispatchQueue.main.async { logLine("Ses hattı denetimi \(attempt): \(summary) | Asistan Mikrofonu’nu kullanan: \(usage)") }
                if let users = users, !users.isEmpty {
                    DispatchQueue.main.async { logLine("Ses hattı doğrulandı" + (switched ? " (sistem mikrofonu geçici olarak Asistan Mikrofonu)" : "")) }
                    return
                }
                // A fresh read showing Asistan Mikrofonu checked is enough when macOS cannot name the recorder.
                if reports.contains(where: { $0.plan?.inputReady == true }) {
                    DispatchQueue.main.async { logLine("Ses hattı menüde doğru; macOS kullanımı ayrıca doğrulayamadı") }
                    return
                }
                if attempt == 3, fallback, !switched, current() {
                    switched = CallAudioRoute.useMicrophoneAsDefaultInput()
                    DispatchQueue.main.async { logLine("Sistem mikrofonu görüşme süresince Asistan Mikrofonu yapıldı: \(switched)") }
                }
            }
            guard current() else { return }
            DispatchQueue.main.async {
                guard let self = self, self.sessionID == sid else { return }
                let text = "⚠️ Arayan asistanı duymuyor olabilir: arama uygulaması Asistan Mikrofonu’nu kullanmıyor. Uygulamanın Ses/Video/Arama menüsünden mikrofonu Asistan Mikrofonu seçin ya da Devral’a basın."
                self.appendLiveNote(text)
                self.notify("Asistanın sesi arayana gitmiyor olabilir", "Arama uygulamasında mikrofonu Asistan Mikrofonu seçin veya görüşmeyi devralın.")
                if self.showLive { self.liveWindow.orderFrontRegardless() }
            }
        }
    }
    func releaseCallRoute() { routeQueue.async { if CallAudioRoute.restoreDefaultInput() { DispatchQueue.main.async { logLine("Sistem mikrofonu eski haline getirildi") } } } }

    func abortPendingCall(_ message: String) {
        releaseCallRoute()
        CallObserver.shared.urgent = false
        sendCommand(["command": "cancel_prewarm"])
        busy = false; inSession = false; sessionID = nil; sessionSource = nil; connectionDeadline = nil; sessionWatchdog = nil
        reportCallFailure(message)
    }

    func reportCallFailure(_ message: String) {
        logLine("Cevaplama durdu: \(message)")
        callFailure = ("Asistan aramayı karşılayamadı", Date().addingTimeInterval(30))
        appendLiveNote("Arama karşılanamadı: " + message)
        if manualAnswer {
            liveWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
        notify("Asistan aramayı karşılayamadı", message)
        updateStatus()
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}


// Beta's preferences (mobile pairing code, auto-answer choices) carry over before any are read.
AppMigration.migratePreferences(legacy: UserDefaults.standard.persistentDomain(forName: AppMigration.legacyBundleID), into: .standard)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

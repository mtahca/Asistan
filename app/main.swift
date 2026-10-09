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

// MARK: - Accessibility yardımcıları

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ name: String) -> String { (attr(el, name) as? String) ?? "" }
func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func actionNames(_ el: AXUIElement) -> [String] {
    var a: CFArray?
    guard AXUIElementCopyActionNames(el, &a) == .success, let arr = a as? [String] else { return [] }
    return arr
}
func labels(_ el: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute, kAXIdentifierAttribute]
        .map { str(el, $0 as String) }
        .filter { !$0.isEmpty }
}
func walk(_ el: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Void) {
    let r = (attr(el, kAXRoleAttribute as String) as? String) ?? ""
    if r == "AXMenuBar" || r == "AXMenuBarItem" || r == "AXMenu" || r == "AXMenuItem" { return }
    visit(el, depth)
    if depth >= 14 { return }
    for c in children(el) { walk(c, depth: depth + 1, visit) }
}
func frameOf(_ el: AXUIElement) -> CGRect? {
    guard let pv = attr(el, kAXPositionAttribute as String),
          let sv = attr(el, kAXSizeAttribute as String) else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos),
          AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: pos, size: size)
}

// Arama kaynağına ait erişilebilir cevaplama kontrolü.

struct ScanResult {
    var button: AXUIElement?
    var endButton: AXUIElement?
    var action: String = kAXPressAction as String
    var groupFrame: CGRect?
    var source: CallSource = .apple
    var texts: [CallerLabel] = []
}

/// Only call-owned windows and notification subtrees may expose an answer button.
func scanCallRoot(_ root: AXUIElement, source: CallSource) -> ScanResult {
    var result = ScanResult(); result.source = source
    var texts: [String] = [], hasDecline = false
    var endCandidate: (AXUIElement, [String])?
    walk(root) { el, depth in
        let values = labels(el)
        texts += values
        let role = str(el, kAXRoleAttribute as String)
        for (attribute, key) in [(CallerAttribute.title, kAXTitleAttribute), (.description, kAXDescriptionAttribute),
                                (.help, kAXHelpAttribute), (.value, kAXValueAttribute), (.identifier, kAXIdentifierAttribute)] {
            let value = str(el, key as String)
            if !value.isEmpty { result.texts.append(CallerLabel(role: role, attribute: attribute, value: value)) }
        }
        if str(el, kAXRoleAttribute as String) == "AXButton" {
            if values.contains(where: CallUI.decline) { hasDecline = true }
            if endCandidate == nil, str(el, kAXSubroleAttribute as String) != "AXCloseButton",
               values.contains(where: CallUI.end) { endCandidate = (el, values) }
            if result.button == nil && values.contains(where: CallUI.answer) { result.button = el }
        }
        if result.button == nil, let action = actionNames(el).first(where: CallUI.answer) {
            result.button = el; result.action = action
        }
    }
    let hasAnswer = result.button != nil
    if let candidate = endCandidate,
       CallUI.connectedEndControl(candidate.1, rootHasAnswer: hasAnswer, rootHasDecline: hasDecline) {
        result.endButton = candidate.0
    }
    if CallUI.videoCall(texts) || (source == .whatsapp && (!hasDecline || !CallUI.voiceIncoming(texts))) { result.button = nil }
    if result.button != nil { result.groupFrame = frameOf(root) }
    return result
}

func notificationRoots(for source: CallSource) -> [AXUIElement] {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return [] }
    var roots: [AXUIElement] = []
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.3)
    walk(application) { el, _ in
        let match = labels(el).contains { text in
            source == .apple ? CallUI.appleNotification(text) : CallUI.normalized(text).contains("whatsapp_notification")
        }
        if match { roots.append(el) }
    }
    return roots
}

func appWindows(for source: CallSource) -> [AXUIElement] {
    source.bundleIDs.flatMap { bid -> [AXUIElement] in
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { return [] }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        return (attr(application, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }
}

// Accessibility calls can wait on another application. Poll on one worker;
// the main thread only consumes the last complete observation.
final class CallObserver {
    static let shared = CallObserver()
    private let queue = DispatchQueue(label: "com.mtahca.asistan.call-observer")
    private let lock = NSLock()
    private var incoming = ScanResult()
    private var controls: [CallSource: AXUIElement] = [:]
    private var connectedCallers: [CallSource: CallerInfo] = [:]
    private var updated = Date.distantPast
    private var started = false
    func start() {
        guard !started else { return }; started = true
        queue.async { self.poll() }
    }
    private func poll() {
        var found = ScanResult(), endings: [CallSource: AXUIElement] = [:]
        var callers: [CallSource: CallerInfo] = [:]
        if AXIsProcessTrusted() {
            for source in [CallSource.apple, .whatsapp] {
                for root in notificationRoots(for: source) + appWindows(for: source) {
                    let result = scanCallRoot(root, source: source)
                    if found.button == nil && result.button != nil { found = result }
                    if endings[source] == nil, let end = result.endButton { endings[source] = end }
                    if result.endButton != nil {
                        let caller = extractCaller(from: result.texts, source: source)
                        if callers[source] == nil || (callers[source]!.name.isEmpty && callers[source]!.number.isEmpty) {
                            callers[source] = caller
                        }
                    }
                }
            }
        }
        lock.lock(); incoming = found; controls = endings; connectedCallers = callers; updated = Date(); lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.6) { self.poll() }
    }
    func result() -> ScanResult {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(updated) < 5 ? incoming : ScanResult()
    }
    func control(_ source: CallSource) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(updated) < 5 ? controls[source] : nil
    }
    func connectedCaller(_ source: CallSource) -> CallerInfo {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(updated) < 5, controls[source] != nil else { return CallerInfo() }
        return connectedCallers[source] ?? CallerInfo()
    }
}
func scanNotifications() -> ScanResult { CallObserver.shared.result() }

/// Tanı: çalışan uygulamanın izinlerini ve arama arayüzünün erişilebilirlik ağacını yazar.
func dumpTree(bundleIDs: [String], to url: URL) {
    var out = "Tanı \(Date())\n"
    out += "Sürüm: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")\n"
    out += "Uygulama: \(Bundle.main.bundleURL.path)\n"
    out += "Erişilebilirlik: \(AXIsProcessTrusted())\n"
    out += "Mikrofon: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)\n"
    for bid in bundleIDs {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else {
            out += "\n== \(bid): çalışmıyor\n"; continue
        }
        out += "\n== \(bid) (pid \(app.processIdentifier))\n"
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let readError = AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &value)
        out += "Arayüz okuma sonucu: \(readError.rawValue)\n"
        var windowValue: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowValue)
        let windows = (windowValue as? [AXUIElement]) ?? []
        out += "Pencere okuma sonucu: \(windowError.rawValue); pencere sayısı: \(windows.count)\n"
        // Some apps expose AXWindows without placing them under AXChildren.
        // Inspect the same roots used by the call observer, not only app children.
        for treeRoot in windows.isEmpty ? [root] : windows {
        walk(treeRoot) { el, depth in
            let role = str(el, kAXRoleAttribute as String)
            let sub = str(el, kAXSubroleAttribute as String)
            let acts = actionNames(el).joined(separator: ",")
            var line = String(repeating: "  ", count: depth) + role
            if !sub.isEmpty { line += "/" + sub }
            let l = labels(el)
            if !l.isEmpty { line += " " + l.map { "\"\($0)\"" }.joined(separator: " ") }
            if !acts.isEmpty { line += " [\(acts)]" }
            if let f = frameOf(el) { line += " \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))" }
            out += line + "\n"
        }
        }
    }
    do {
        try out.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch { logLine("Tanı kaydedilemedi: \(error.localizedDescription)") }
}

// MARK: - Ses kullanan süreçler (tanı)

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

/// Hangi süreçler şu an ses girişi/çıkışı kullanıyor (macOS 14.2+)
func audioProcessReport() -> String {
    var addr = AudioObjectPropertyAddress(mSelector: fourCC("prs#"), mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(hwSystem, &addr, 0, nil, &size) == noErr, size > 0 else { return "(süreç listesi yok)" }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(hwSystem, &addr, 0, nil, &size, &ids) == noErr else { return "(okunamadı)" }
    var out: [String] = []
    for id in ids {
        func u32(_ sel: String) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: fourCC(sel), mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0; var sz = UInt32(4)
            _ = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v)
            return v
        }
        var bid = ""
        var a = AudioObjectPropertyAddress(mSelector: fourCC("pbid"), mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if withUnsafeMutablePointer(to: &cf, { AudioObjectGetPropertyData(id, &a, 0, nil, &sz, $0) }) == noErr, let c = cf { bid = c.takeRetainedValue() as String }
        let rin = u32("piri"), rout = u32("piro")
        if rin != 0 || rout != 0 { out.append("\(bid)(pid \(u32("ppid")))\(rin != 0 ? " GİRİŞ" : "")\(rout != 0 ? " ÇIKIŞ" : "")") }
    }
    return out.isEmpty ? "(kimse ses kullanmıyor)" : out.joined(separator: "; ")
}

var defaultListenerInstalled = false
func installDefaultListeners() {
    guard !defaultListenerInstalled else { return }
    defaultListenerInstalled = true
    for (sel, name) in [(kAudioHardwarePropertyDefaultInputDevice, "giriş"), (kAudioHardwarePropertyDefaultOutputDevice, "çıkış")] {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(hwSystem, &addr, DispatchQueue.main) { _, _ in
            let d = getDefault(sel).map(deviceName) ?? "?"
            logLine("[izleme] varsayılan \(name) -> \(d) | ses kullananlar: \(audioProcessReport())")
        }
    }
}

// MARK: - Ses cihazları (CoreAudio)

let hwSystem = AudioObjectID(kAudioObjectSystemObject)

func deviceID(forUID uid: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = withUnsafeMutablePointer(to: &cfUID) { p in
        AudioObjectGetPropertyData(hwSystem, &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
    }
    return (st == noErr && dev != 0) ? dev : nil
}

func getDefault(_ sel: AudioObjectPropertySelector) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioObjectGetPropertyData(hwSystem, &addr, 0, nil, &size, &dev)
    return (st == noErr && dev != 0) ? dev : nil
}

@discardableResult
func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(hwSystem, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(hwSystem, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func hasStreams(_ d: AudioDeviceID, input: Bool) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size) == noErr && size > 0
}

func transportType(_ d: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &t)
    return t
}

func deviceUIDString(_ d: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(d, &addr, 0, nil, &size, $0) }
    if st == noErr, let u = cf { return u.takeRetainedValue() as String }
    return ""
}

func deviceName(_ d: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(d, &addr, 0, nil, &size, $0) }
    if st == noErr, let u = cf { return u.takeRetainedValue() as String }
    return deviceUIDString(d)
}

func builtinDevice(input: Bool) -> AudioDeviceID? {
    allDevices().first { hasStreams($0, input: input) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
}

func namedAudioDevice(_ name: String, input: Bool) -> AudioDeviceID? {
    let matches = allDevices().filter { deviceName($0) == name && hasStreams($0, input: input) }
    return matches.count == 1 ? matches[0] : nil
}

func loopbackAudioReady() -> Bool {
    guard let listen = namedAudioDevice(BetaAudio.listenName, input: true),
          let microphone = namedAudioDevice(BetaAudio.microphoneName, input: true),
          let playback = namedAudioDevice(BetaAudio.playbackName, input: false) else { return false }
    return Set([listen, microphone, playback]).count == 3
}

// MARK: - Arayan bilgisi (banner metni + Rehber)

/// Rehberden eksik bilgiyi (isim <-> numara) tamamlar
func enrichFromContacts(_ info: CallerInfo) -> CallerInfo {
    var out = info
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
        logLine("Rehber izni yok; sadece banner bilgisi kullanılıyor")
        return out
    }
    let store = CNContactStore()
    let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor,
                                   CNContactFamilyNameKey as CNKeyDescriptor,
                                   CNContactNicknameKey as CNKeyDescriptor,
                                   CNContactPhoneNumbersKey as CNKeyDescriptor]
    func fullName(_ c: CNContact) -> String {
        let n = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? c.nickname : n
    }
    do {
        if !info.number.isEmpty && info.name.isEmpty {
            let pred = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: info.number))
            if let c = try store.unifiedContacts(matching: pred, keysToFetch: keys).first {
                out.name = fullName(c)
                out.inContacts = true
            }
        } else if !info.name.isEmpty {
            let pred = CNContact.predicateForContacts(matchingName: info.name)
            var matches = try store.unifiedContacts(matching: pred, keysToFetch: keys)
            if matches.isEmpty {
                // takma ad ("Aşkım" gibi) için tüm kişilerde ara
                let req = CNContactFetchRequest(keysToFetch: keys)
                var found: [CNContact] = []
                try store.enumerateContacts(with: req) { c, _ in
                    if c.nickname.lowercased() == info.name.lowercased() { found.append(c) }
                }
                matches = found
            }
            if matches.count == 1, let c = matches.first,
               fullName(c).caseInsensitiveCompare(info.name) == .orderedSame || c.nickname.caseInsensitiveCompare(info.name) == .orderedSame {
                out.inContacts = true
                // The actual incoming number must come from the call, not the first contact number.
                let fn = fullName(c)
                if !fn.isEmpty && fn.lowercased() != info.name.lowercased() { out.name = "\(info.name) (\(fn))" }
            }
        }
    } catch {
        logLine("Rehber araması başarısız: \(error)")
    }
    return out
}



/// Controls belong to the call source captured when answering, never another app.
func callControl(for source: CallSource) -> AXUIElement? { CallObserver.shared.control(source) }

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
    var recentMenu: NSMenu!
    var ringerName = ""
    var ringDiagnosticSaved = false
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
        mobile.startIfEnabled()
        if let notes = try? FileManager.default.contentsOfDirectory(at: projectDir.appendingPathComponent("notlar"), includingPropertiesForKeys: nil) {
            lastNotePath = notes.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last?.path
        }
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
        presets.addItem(withTitle: "Hazır notlar")
        for text in Self.quickNotes { presets.addItem(withTitle: text) }
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

    static let quickNotes = [
        "Şu an müsait değilim; en kısa sürede dönüş yapacağım.",
        "Mesajını ve geri dönüş numarasını not al.",
        "Konuyu kısaca öğren, sonra görüşmeyi kibarca bitir.",
        "Acil bir durumsa bana hemen mesaj atmasını söyle.",
    ]
    @objc func chooseQuickNote(_ sender: NSPopUpButton) {
        guard let text = sender.selectedItem?.title, Self.quickNotes.contains(text) else { return }
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
        let a = NSMutableAttributedString()
        a.append(NSAttributedString(string: speaker + ": ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: color]))
        a.append(NSAttributedString(string: text + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        liveText.textStorage?.append(a)
        scrollLiveIfFollowing()
    }

    func appendLiveNote(_ text: String) {
        if !renderingLive {
            liveFollow = liveAtBottom()
            if text != liveCallerHeading { liveExtras.append(("", text, nil)) }
            mobile.append(kind: text.contains("Arayan araya girdi") ? "interrupted" : "note", speaker: "", text: text)
        }
        liveText.textStorage?.append(NSAttributedString(string: text + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
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
        var out = "Arayan bulunamadı — \(Date())\nKaynak: \(result.source.rawValue)\n\n"
        for label in result.texts { out += "\(label.role) \(label.attribute): \(label.value.replacingOccurrences(of: "\n", with: "⏎"))\n" }
        let url = projectDir.appendingPathComponent("son_arama_tani.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        logLine("Arayan bulunamadı; bildirim yapısı kaydedildi: \(url.lastPathComponent)")
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
            if self.pressAnswer(incoming) { self.connectionDeadline = Date().addingTimeInterval(8); logLine("Aramanın bağlanması bekleniyor") }
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
    func validNotePath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent() == projectDir.appendingPathComponent("notlar").standardizedFileURL && url.pathExtension == "md"
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

// MARK: - Ses ayarları penceresi

final class SoundPrefsController: NSObject {
    let app: AppDelegate
    var window: NSWindow!
    var info: NSTextField!
    var microphones: NSPopUpButton!
    var feedback: NSTextField!
    var routeInfo: NSTextField!
    var routeButton: NSButton!
    var fallbackToggle: NSButton!
    init(app: AppDelegate) { self.app = app; super.init() }
    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Asistan — Kalıcı ses hattı"; window.isReleasedWhenClosed = false
        let content = window.contentView!
        let title = NSTextField(labelWithString: "Ses hattı: Loopback")
        title.font = .boldSystemFont(ofSize: 16); title.frame = NSRect(x: 20, y: 496, width: 500, height: 24); content.addSubview(title)
        info = NSTextField(wrappingLabelWithString: "")
        info.isSelectable = true; info.frame = NSRect(x: 20, y: 350, width: 500, height: 142); content.addSubview(info)
        let micLabel = NSTextField(labelWithString: "Devralırken kullanacağım mikrofon")
        micLabel.frame = NSRect(x: 20, y: 320, width: 500, height: 22); content.addSubview(micLabel)
        microphones = NSPopUpButton(frame: NSRect(x: 20, y: 285, width: 500, height: 30), pullsDown: false)
        microphones.target = self; microphones.action = #selector(selectMicrophone); content.addSubview(microphones)
        feedback = NSTextField(wrappingLabelWithString: "")
        feedback.frame = NSRect(x: 20, y: 236, width: 500, height: 44); content.addSubview(feedback)
        let refresh = NSButton(title: "Durumu yenile", target: self, action: #selector(refresh))
        refresh.bezelStyle = .rounded; refresh.frame = NSRect(x: 20, y: 198, width: 140, height: 30); content.addSubview(refresh)
        let open = NSButton(title: "Loopback’i aç", target: self, action: #selector(openLoopback))
        open.bezelStyle = .rounded; open.frame = NSRect(x: 176, y: 198, width: 160, height: 30); content.addSubview(open)
        let routeTitle = NSTextField(labelWithString: "Arama uygulamalarının mikrofonu ve hoparlörü")
        routeTitle.font = .boldSystemFont(ofSize: 13); routeTitle.frame = NSRect(x: 20, y: 162, width: 500, height: 20); content.addSubview(routeTitle)
        routeInfo = NSTextField(wrappingLabelWithString: "Her görüşmede Asistan, Telefon/FaceTime/WhatsApp menüsünden mikrofonu Asistan Mikrofonu yapar ve macOS’tan doğrular. Görüşmeden önce denetlemek için aşağıdaki düğmeyi kullanın.")
        routeInfo.isSelectable = true; routeInfo.frame = NSRect(x: 20, y: 82, width: 500, height: 76); content.addSubview(routeInfo)
        fallbackToggle = NSButton(checkboxWithTitle: "Doğrulanamazsa görüşme süresince sistem mikrofonunu Asistan Mikrofonu yap", target: self, action: #selector(toggleFallback))
        fallbackToggle.frame = NSRect(x: 20, y: 52, width: 500, height: 22); content.addSubview(fallbackToggle)
        routeButton = NSButton(title: "Uygulamaları denetle ve düzelt", target: self, action: #selector(checkCallApps))
        routeButton.bezelStyle = .rounded; routeButton.frame = NSRect(x: 20, y: 14, width: 260, height: 30); content.addSubview(routeButton)
    }
    @objc func toggleFallback() {
        app.routeFallback = fallbackToggle.state == .on
        UserDefaults.standard.set(app.routeFallback, forKey: "routeFallbackDefaultInput")
    }
    @objc func checkCallApps() {
        guard !app.busy else { routeInfo.stringValue = "Görüşme sürüyor; bu görüşmenin ses hattı zaten otomatik denetleniyor."; return }
        routeButton.isEnabled = false; routeInfo.stringValue = "Denetleniyor… Uygulamalar kısa süre öne gelebilir."
        let preferred = getDefault(kAudioHardwarePropertyDefaultOutputDevice).map(deviceName)
        app.routeQueue.async { [weak self] in
            var reports: [RouteReport] = []
            for target in CallAudioRoute.apps {
                let report = CallAudioRoute.check(bundleID: target.bundleID, name: target.name, apply: true, preferredOutput: preferred)
                // WhatsApp has two identifiers; show the running one only.
                if let index = reports.firstIndex(where: { $0.app == report.app }) {
                    if !reports[index].running { reports[index] = report }
                } else { reports.append(report) }
            }
            let lines = reports.map { $0.summary }.joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.routeButton.isEnabled = true
                self.routeInfo.stringValue = lines + "\nÇalışmayan uygulamayı açıp yeniden deneyin. Liste bulunamazsa o uygulamanın menüsünden mikrofonu elle Asistan Mikrofonu seçin."
            }
        }
    }
    @objc func refresh() {
        let listen = namedAudioDevice(BetaAudio.listenName, input: true) != nil
        let mic = namedAudioDevice(BetaAudio.microphoneName, input: true) != nil
        let playback = namedAudioDevice(BetaAudio.playbackName, input: false) != nil
        info.stringValue = "\(listen ? "✅" : "⬜️") Arayanın sesi: Asistan Dinleme\n\(playback ? "✅" : "⬜️") Asistan’ın sesi: Asistan Ses Çıkışı\n\(mic ? "✅" : "⬜️") Arama uygulamalarının mikrofonu: Asistan Mikrofonu\n\nArama başında ve sonunda aygıt değiştirilmez.\nDevral’da kendi mikrofonunuz aynı hatta aktarılır."
        let selected = UserDefaults.standard.string(forKey: "humanMicrophoneUID") ?? ""
        microphones.removeAllItems(); microphones.addItem(withTitle: "Yerleşik mikrofon (otomatik)")
        microphones.lastItem?.representedObject = ""
        for device in allDevices().filter({ hasStreams($0, input: true) && transportType($0) != kAudioDeviceTransportTypeVirtual }) {
            let uid = deviceUIDString(device)
            if uid.isEmpty { continue }
            microphones.addItem(withTitle: deviceName(device)); microphones.lastItem?.representedObject = uid
        }
        if let item = microphones.itemArray.first(where: { ($0.representedObject as? String) == selected }) { microphones.select(item) }
        else {
            microphones.addItem(withTitle: "Seçili mikrofon bağlı değil")
            microphones.lastItem?.representedObject = selected; microphones.select(microphones.lastItem)
        }
        fallbackToggle.state = app.routeFallback ? .on : .off
        feedback.stringValue = "Seçim bir sonraki aramada kullanılır. Sistem ses ayarları değiştirilmez. Bağlı olmayan mikrofonla Devral sesi açılamaz."
    }
    @objc func selectMicrophone() {
        guard let uid = microphones.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: "humanMicrophoneUID")
        feedback.stringValue = "Kaydedildi. Bir sonraki aramada Devral için bu mikrofon kullanılacak."
    }
    @objc func openLoopback() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Loopback.app"), configuration: NSWorkspace.OpenConfiguration())
    }
    func show() { if window == nil { build() }; refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

// Beta's preferences (mobile pairing code, auto-answer choices) carry over before any are read.
AppMigration.migratePreferences(legacy: UserDefaults.standard.persistentDomain(forName: AppMigration.legacyBundleID), into: .standard)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

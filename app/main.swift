// Asistan — menü çubuğu uygulaması
// Gelen FaceTime/iPhone aramasında "Asistanla Cevapla" düğmesi gösterir.
// Gelen FaceTime/Telefon/WhatsApp aramasını Loopback sanal aygıtlarıyla (sistem ses ayarına dokunmadan) cevaplar, Python ajanını (agent.py) başlatır.
// Aramayı sen açarsan asistan devreye girmez.

import Cocoa
import ApplicationServices
import AVFoundation
import CoreAudio
import UserNotifications
import Contacts
import Vision
import ServiceManagement

let answerWords = ["answer", "yanıtla", "yanitla", "cevapla"]
let rejectWords = ["decline", "reject", "reddet", "ignore", "dismiss", "close", "kapat"]

var logHandle: FileHandle?
func logLine(_ s: String) {
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
func isAnswer(_ text: String) -> Bool {
    let t = text.lowercased()
    return answerWords.contains { t.contains($0) } && !rejectWords.contains { t.contains($0) }
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
func clickAt(_ p: CGPoint) {
    let saved = CGEvent(source: nil)?.location ?? p
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: saved, mouseButton: .left)?.post(tap: .cghidEventTap)
}

// Bildirim çerçevesine göre "cevapla" düğmesi konumları (ekran görüntüsünden ölçüldü)
let largeRel = CGPoint(x: 0.864, y: 0.073)
let compactRel = CGPoint(x: 0.861, y: 0.316)

struct ScanResult {
    var button: AXUIElement?
    var action: String = kAXPressAction as String
    var groupFrame: CGRect?
    var source = "FaceTime"
    var texts: [String] = []   // bildirimdeki tüm metinler (arayan bilgisi için)
}

/// WhatsApp Masaüstü'nün gelen SESLİ arama penceresi. Gerçek arayüzde (Codex/Loopback denemesinde doğrulandı):
/// başlık "WhatsApp audio call", kabul düğmesi CallUI_AcceptButton, ret düğmesi CallUI_DeclineButton ("hang up").
/// Ses, Loopback'in "Asistan Dinleme" aygıtındaki WhatsApp kaynağından alınır; mikrofon olarak WhatsApp'ta
/// "Asistan Mikrofonu" seçili olmalıdır.
let whatsappEnabled = true

func normUI(_ t: String) -> String {
    let hidden: Set<UInt32> = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
    var out = String.UnicodeScalarView()
    for u in t.unicodeScalars where !hidden.contains(u.value) { out.append(u) }
    return String(out).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
}

func scanWhatsApp() -> ScanResult {
    var res = ScanResult()
    guard whatsappEnabled else { return res }
    for bid in ["net.whatsapp.WhatsApp", "desktop.WhatsApp"] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { continue }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let wins = attr(root, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
        for w in wins {
            // Arama penceresi küçüktür; büyük sohbet penceresinin ağacını her turda gezmeyelim (yavaş)
            if let f = frameOf(w), f.width > 700 || f.height > 760 { continue }
            var accept: AXUIElement?
            var hasDecline = false
            var texts: [String] = []
            var all: [String] = []
            walk(w) { el, depth in
                let role = str(el, kAXRoleAttribute as String)
                let lbls = labels(el)
                for t in lbls {
                    all.append(normUI(t))
                    if role == "AXStaticText" {
                        let e = "\(role) d\(depth): \(t)"
                        if !texts.contains(e) { texts.append(e) }
                    }
                }
                if role == "AXButton" {
                    let n = lbls.map(normUI)
                    if n.contains(where: { ["callui_acceptbutton", "accept call", "answer call", "accept", "answer"].contains($0) }) { accept = el }
                    if n.contains(where: { ["callui_declinebutton", "decline", "decline call", "hang up", "reddet"].contains($0) }) { hasDecline = true }
                }
            }
            // Arayan adı WhatsApp pencere başlığında gelir: "Ad - WhatsApp audio call" (SceneWindow vb. kimlikler kullanılmaz)
            let winTitle = str(w, kAXTitleAttribute as String)
            for suffix in [" - WhatsApp voice call", " - WhatsApp audio call"] {
                if let r = winTitle.range(of: suffix, options: [.caseInsensitive, .backwards]), r.upperBound == winTitle.endIndex {
                    let name = String(winTitle[winTitle.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { texts.insert("AXStaticText d0: \(name)", at: 0) }
                }
            }
            all.append(normUI(winTitle))
            let videoMarks = ["incoming video call", "facetime video", "görüntülü arama", "video call incoming", "whatsapp video call"]
            let voiceMarks = ["incoming call", "incoming voice call", "incoming audio call", "gelen arama", "gelen sesli arama"]
            var isVideo = false, voice = false
            for t in all {
                for m in videoMarks where t.contains(m) { isVideo = true }
                for m in voiceMarks where t.contains(m) { voice = true }
                if t.contains("whatsapp audio call") || t.contains("whatsapp voice call") { voice = true }
            }
            // Bağlı görüşmede kabul düğmesi yoktur; "hang up" tek başına gelen arama sayılmaz.
            if let a = accept, hasDecline, voice, !isVideo {
                res.button = a
                res.action = kAXPressAction as String
                res.groupFrame = frameOf(w)
                res.texts = texts
                res.source = "WhatsApp"
                return res
            }
        }
    }
    return res
}

func scanNotifications() -> ScanResult {
    let r = scanFaceTime()
    if r.button != nil || r.groupFrame != nil { return r }
    let w = scanWhatsApp()
    return w.button != nil ? w : r
}

func scanFaceTime() -> ScanResult {
    var res = ScanResult()
    guard let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.notificationcenterui").first else { return res }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    var groupFound = false
    var groupDepth: Int? = nil
    var groupDone = false
    walk(root) { el, depth in
        let role = str(el, kAXRoleAttribute as String)
        let lbls = labels(el)
        // Yalnızca FaceTime bildiriminin alt ağacındaki metinleri topla (widget'lar karışmasın)
        let isCallGroup = lbls.contains(where: {
            $0.lowercased().contains("facetime notification") || $0.uppercased().contains("FACETIME_NOTIFICATION")
        })
        if let d = groupDepth, depth <= d { groupDepth = nil; groupDone = true }
        if groupDepth == nil && !groupDone && isCallGroup { groupDepth = depth }
        if groupDepth != nil {
            for t in lbls { let e = "\(role) d\(depth): \(t)"; if !res.texts.contains(e) { res.texts.append(e) } }
        }
        if !groupFound, lbls.contains(where: {
            $0.uppercased().contains("FACETIME_NOTIFICATION") || $0.lowercased().contains("facetime notification")
        }) {
            groupFound = true
            res.groupFrame = frameOf(el)
        }
        if res.button != nil { return }
        if role == "AXButton", lbls.contains(where: isAnswer) {
            res.button = el
            res.action = kAXPressAction as String
            return
        }
        if let act = actionNames(el).first(where: isAnswer) {
            res.button = el
            res.action = act
        }
    }
    return res
}

/// Tanı: bildirim merkezi ve WhatsApp pencerelerinin erişilebilirlik ağacını dosyaya yazar
func dumpTree(bundleIDs: [String], to url: URL) {
    var out = "Tanı \(Date())\n"
    for bid in bundleIDs {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else {
            out += "\n== \(bid): çalışmıyor\n"; continue
        }
        out += "\n== \(bid) (pid \(app.processIdentifier))\n"
        let root = AXUIElementCreateApplication(app.processIdentifier)
        walk(root) { el, depth in
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
    try? out.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - FaceTime menüsünden cihaz seçimi (arama sırasında FaceTime cihazı kilitleyebiliyor)

func menuTitle(_ el: AXUIElement) -> String { str(el, kAXTitleAttribute as String) }

func menuItems(of el: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    for c in children(el) {
        if str(c, kAXRoleAttribute as String) == "AXMenu" { out += children(c) } else { out.append(c) }
    }
    return out
}

/// FaceTime > Video menüsünde "Microphone" (giriş) ya da "Output" (çıkış) bölümündeki,
/// adı `keys` parçalarından birini içeren öğeyi seçer. Bölümler başlık satırlarıyla ayrılmıştır.
func facetimePickDevice(input: Bool, keys: [String]) -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FaceTime").first else {
        logLine("FaceTime çalışmıyor"); return false
    }
    // Arka plandaki uygulamanın menü çubuğu boş/pasif olabiliyor: FaceTime'ı kısa süre öne al
    let prev = NSWorkspace.shared.frontmostApplication
    let wasFront = app.isActive
    if !wasFront { app.activate(options: []); usleep(600_000) }
    defer { if !wasFront { prev?.activate(options: []) } }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    var barRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &barRef)
    guard err == .success, let bar = barRef else { logLine("FaceTime menü çubuğu okunamadı (\(err.rawValue))"); return false }
    let tops = children(bar as! AXUIElement)
    logLine("FaceTime üst menüler: \(tops.map(menuTitle))")
    let micHeads = ["microphone", "mikrofon"], outHeads = ["output", "çıkış", "speaker", "hoparlör"]
    for top in tops where ["video", "görüntülü"].contains(where: { menuTitle(top).lowercased().contains($0) }) {
        let items = menuItems(of: top)
        var section = ""    // "in" | "out"
        var candidates: [AXUIElement] = []
        for it in items {
            let t = menuTitle(it).lowercased()
            if micHeads.contains(where: { t == $0 }) { section = "in"; continue }
            if outHeads.contains(where: { t == $0 }) { section = "out"; continue }
            if section == (input ? "in" : "out"), !t.isEmpty { candidates.append(it) }
        }
        logLine("FaceTime \(input ? "mikrofon" : "çıkış") seçenekleri: \(candidates.map(menuTitle)) (Video menüsü öğe sayısı: \(items.count))")
        for k in keys where !k.isEmpty {
            let kl = k.lowercased()
            let wantSystem = kl.contains("system") || kl.contains("sistem")
            if let it = candidates.first(where: { c in
                let t = menuTitle(c).lowercased()
                if wantSystem { return t.contains(kl) }
                return t.contains(kl) && !t.contains("system setting") && !t.contains("sistem ayar")
            }) {
                let ok = AXUIElementPerformAction(it, kAXPressAction as CFString) == .success
                logLine("FaceTime -> \(menuTitle(it)): \(ok)")
                return ok
            }
        }
    }
    return false
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
func setDefault(_ sel: AudioObjectPropertySelector, _ dev: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(hwSystem, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
}

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

/// Kullanıcının kendi (insan) ses cihazı tercihi; boşsa aramadan önceki sistem ayarı kullanılır
func userPreferredDevice(input: Bool) -> AudioDeviceID? {
    guard let uid = UserDefaults.standard.string(forKey: input ? "userInUID" : "userOutUID"), !uid.isEmpty,
          let d = deviceID(forUID: uid), hasStreams(d, input: input) else { return nil }
    return d
}

func builtinDevice(input: Bool) -> AudioDeviceID? {
    allDevices().first { hasStreams($0, input: input) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
}

// MARK: - Loopback sabit aygıtları (BlackHole yok; sistem varsayılanları değiştirilmez)

enum BetaAudio {
    static let listenName = "Asistan Dinleme"          // arayanın sesi: FaceTime/Telefon/WhatsApp uygulama sesi
    static let microphoneName = "Asistan Mikrofonu"    // arama uygulamasının mikrofonu (Ses Çıkışı'ndan beslenir)
    static let playbackName = "Asistan Ses Çıkışı"     // asistanın sesinin gittiği yer
}

func nfc(_ t: String) -> String { t.precomposedStringWithCanonicalMapping.lowercased() }

/// Adı tam eşleşen TEK aygıt (yinelenen adlar reddedilir; macOS adları NFC/NFD farklı olabilir)
func namedAudioDevice(_ name: String, input: Bool) -> AudioDeviceID? {
    let wanted = nfc(name)
    let m = allDevices().filter { nfc(deviceName($0)) == wanted && hasStreams($0, input: input) }
    return m.count == 1 ? m[0] : nil
}

func loopbackStatus() -> (listen: Bool, mic: Bool, playback: Bool) {
    (namedAudioDevice(BetaAudio.listenName, input: true) != nil,
     namedAudioDevice(BetaAudio.microphoneName, input: true) != nil,
     namedAudioDevice(BetaAudio.playbackName, input: false) != nil)
}

func loopbackAudioReady() -> Bool {
    let s = loopbackStatus()
    return s.listen && s.mic && s.playback
}

func forceFullVolume(uid: String) {
    guard let dev = deviceID(forUID: uid) else { return }
    for scope in [kAudioDevicePropertyScopeOutput, kAudioDevicePropertyScopeInput] {
        for el in UInt32(0)...2 {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var cur: Float32 = 0
            var sz = UInt32(MemoryLayout<Float32>.size)
            _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &cur)
            if abs(cur - 1.0) > 0.01 {
                var v: Float32 = 1.0
                _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
                logLine("\(uid) ses seviyesi \(cur) -> 1.0")
            }
        }
    }
}


// MARK: - Arayan bilgisi (banner metni + Rehber)

struct CallerInfo {
    var name: String = ""
    var number: String = ""
    var inContacts = false
    var firstName: String = ""   // rehberdeki gerçek ad (takma ad değil); kişisel karşılama için
}

func looksLikeNumber(_ t: String) -> Bool {
    let digits = t.filter { $0.isNumber }
    let allowed = t.allSatisfy { $0.isNumber || " +-()\u{A0}".contains($0) }
    return allowed && digits.count >= 7
}



/// Devam eden aramayı kapatır: bildirim merkezi ve FaceTime/Telefon (ya da WhatsApp) pencerelerindeki "End / Bitir" düğmesine basar.
@discardableResult
func hangUpCall(whatsapp: Bool = false) -> String {
    let exact = ["end", "end call", "hang up", "leave call", "bitir", "aramayı bitir", "sonlandır", "aramayı sonlandır", "kapat"]
    let bundles = whatsapp ? ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]
                           : ["com.apple.notificationcenterui", "com.apple.FaceTime", "com.apple.mobilephone"]
    for bid in bundles {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var target: AXUIElement?
            walk(root) { el, _ in
                if target != nil { return }
                let role = str(el, kAXRoleAttribute as String)
                guard role == "AXButton" else { return }
                if str(el, kAXSubroleAttribute as String) == "AXCloseButton" { return }
                if labels(el).contains(where: { exact.contains(normUI($0)) }) { target = el }
            }
            if let t = target, AXUIElementPerformAction(t, kAXPressAction as CFString) == .success {
                return bid
            }
        }
    }
    return ""
}


/// Arama bannerındaki kırmızı "kapat" düğmesini ekran görüntüsünden renginden bulup tıklar.
/// (macOS'ta banner düğmeleri erişilebilirlik ağacında görünmüyor; Ekran Kaydı izni gerekir.)
func hangUpByRedButton() -> Bool {
    guard let scr = NSScreen.main else { return false }
    let W = scr.frame.width
    let region = CGRect(x: max(0, W - 560), y: 0, width: min(560, W), height: 300)
    let tmp = NSTemporaryDirectory() + "asistan_hangup.png"
    try? FileManager.default.removeItem(atPath: tmp)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", tmp]
    do { try p.run(); p.waitUntilExit() } catch { return false }
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    guard let data = FileManager.default.contents(atPath: tmp),
          let rep = NSBitmapImageRep(data: data) else { return false }
    let pw = rep.pixelsWide, ph = rep.pixelsHigh
    guard pw > 0, ph > 0 else { return false }
    let scale = CGFloat(pw) / region.width
    var minX = pw, maxX = -1, minY = ph, maxY = -1, count = 0
    for y in 0..<ph {
        for x in 0..<pw {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            if r > 0.72 && g < 0.34 && b < 0.34 {
                count += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    guard count > 0 else { logLine("Kapat düğmesi: kırmızı alan bulunamadı"); return false }
    let bw = CGFloat(maxX - minX + 1) / scale, bh = CGFloat(maxY - minY + 1) / scale
    guard bw >= 18, bw <= 70, bh >= 18, bh <= 70, abs(bw - bh) < 12 else {
        logLine("Kapat düğmesi: kırmızı alan düğmeye benzemiyor (\(Int(bw))x\(Int(bh)))")
        return false
    }
    let cx = region.minX + CGFloat(minX + maxX) / 2 / scale
    let cy = region.minY + CGFloat(minY + maxY) / 2 / scale
    clickAt(CGPoint(x: cx, y: cy))
    return true
}

/// Banner'ın erişilebilirlik ağacı etiket vermiyorsa (bazı macOS sürümleri) ekran görüntüsünden okur.
/// Ekran Kaydı izni gerekir; yoksa boş döner.
enum ContactWords {
    static var cache: [String]?
    /// Rehberdeki ad, soyad ve takma adlar (OCR'a ipucu olarak verilir)
    static func load() -> [String] {
        if let c = cache { return c }
        var words = Set<String>()
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized {
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor,
                                           CNContactFamilyNameKey as CNKeyDescriptor,
                                           CNContactNicknameKey as CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: req) { c, _ in
                for w in [c.givenName, c.familyName, c.nickname] where !w.isEmpty { words.insert(w) }
                let full = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
                if full.contains(" ") { words.insert(full) }
            }
        }
        let out = Array(words.prefix(1500))
        cache = out
        return out
    }
}

func contactWords() -> [String] {
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
    let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                                   CNContactNicknameKey as CNKeyDescriptor]
    var words = Set<String>()
    try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
        for t in [c.givenName, c.familyName, c.nickname] {
            for w in t.split(separator: " ") where w.count >= 2 { words.insert(String(w)) }
        }
    }
    return Array(words.prefix(800))
}

var ocrLangLogged = false
func ocrBanner(frame: CGRect) -> [String] {
    let tmp = NSTemporaryDirectory() + "asistan_banner.png"
    try? FileManager.default.removeItem(atPath: tmp)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))", tmp]
    do { try p.run(); p.waitUntilExit() } catch { return [] }
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    guard let img = NSImage(contentsOfFile: tmp),
          var cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
    // Küçük, bulanık arka planlı yazıda doğruluk için 3 kat büyüt
    let k = 3
    if let ctx = CGContext(data: nil, width: cg.width * k, height: cg.height * k, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width * k, height: cg.height * k))
        if let big = ctx.makeImage() { cg = big }
    }
    var lines: [String] = []
    let req = VNRecognizeTextRequest { r, _ in
        for o in (r.results as? [VNRecognizedTextObservation]) ?? [] {
            if let t = o.topCandidates(1).first?.string, !t.isEmpty { lines.append(t) }
        }
    }
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    let supported = (try? req.supportedRecognitionLanguages()) ?? []
    if !ocrLangLogged {
        ocrLangLogged = true
        logLine("OCR dilleri: \(supported.joined(separator: ", "))")
    }
    let langs = ["tr-TR", "en-US"].filter { supported.contains($0) }
    if !langs.isEmpty { req.recognitionLanguages = langs }
    req.customWords = contactWords()     // Rehber adları (rehberdeki kısa adlar, soyadlar …) tanımayı doğru kelimeye çeker
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return lines
}

/// Bildirimdeki metinlerden arayanın adını/numarasını çıkarır.
/// Bildirimde arayan "‪Ad Soyad‬, FaceTime Audio" ya da "Ad, From Your iPhone" biçiminde tek bir etikette durur.
func extractCaller(from texts: [String]) -> CallerInfo {
    let typeWords = ["facetime", "iphone", "audio", "video", "mobile", "cellular", "telefon", "phone", "arama", "ses"]
    let junk = ["menucontrolidentifier", "avatar", "widget", "xmark", "notification", "answer", "decline",
                "keypad", "mute", "end", "more", "accept", "kabul", "whatsapp", "scenewindow", "callui_"]
    func clean(_ t: String) -> String {
        // görünmez yön işaretlerini (U+200E/F, U+202A-202E, U+2066-2069) at
        let bad = Set<Unicode.Scalar>((0x202A...0x202E).compactMap { Unicode.Scalar($0) }
            + (0x2066...0x2069).compactMap { Unicode.Scalar($0) }
            + [Unicode.Scalar(0x200E)!, Unicode.Scalar(0x200F)!])
        var out = String(String.UnicodeScalarView(t.unicodeScalars.filter { !bad.contains($0) }))
        if let r = out.range(of: " - ", options: .backwards), out[r.upperBound...].contains(":") {
            out = String(out[out.startIndex..<r.lowerBound])      // " - 0:00" gibi süre eki
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func label(_ e: String) -> String {
        guard let r = e.range(of: ": ") else { return e }
        return String(e[r.upperBound...])
    }
    var info = CallerInfo()
    func assign(_ v: String) {
        if looksLikeNumber(v) { if info.number.isEmpty { info.number = v } }
        else if info.name.isEmpty { info.name = v }
    }
    // 0) OCR satırları: arayanın adı "<arama türü>" satırının hemen üstündeki satırdır ("AI | y in | Ad Soyad | FaceTime Audio").
    //    Avatar baş harfleri ("AI") ve simgelerin okunmuş hali ad sanılmasın.
    for (i, e) in texts.enumerated() where i > 0 && e.hasPrefix("OCR:") {
        let t = clean(label(e)).lowercased()
        if t.count <= 24 && !t.contains(",") && typeWords.contains(where: { t.contains($0) }) {
            let prev = clean(label(texts[i - 1]))
            let pl = prev.lowercased()
            if prev.count >= 3 && prev.count <= 60 && !looksLikeNumber(prev)
                && !junk.contains(where: { pl.contains($0) }) && !typeWords.contains(where: { pl.contains($0) }) {
                assign(prev)
                return info
            }
        }
    }
    // 1) "Ad, <arama türü>" biçimindeki etiket
    for e in texts {
        let t = clean(label(e))
        guard let r = t.range(of: ", ", options: .backwards) else { continue }
        let tail = t[r.upperBound...].lowercased()
        if typeWords.contains(where: { tail.contains($0) }) {
            let who = String(t[t.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !who.isEmpty && !junk.contains(where: { who.lowercased().contains($0) }) {
                assign(who)
                return info
            }
        }
    }
    // 2) Yedek: kısa, anlamlı tek metinler
    for e in texts {
        let t = clean(label(e))
        let l = t.lowercased()
        if t.isEmpty || t.count < 3 || t.count > 60 || junk.contains(where: { l.contains($0) }) { continue }
        if typeWords.contains(where: { l.contains($0) }) { continue }
        assign(t)
    }
    return info
}


/// Ad karşılaştırması için: küçük harf, aksansız, yalnızca harf/rakam
func normName(_ t: String) -> String {
    t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
        .lowercased().filter { $0.isLetter || $0.isNumber }
}
func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var prev = Array(0...y.count)
    for i in 1...x.count {
        var cur = [i] + Array(repeating: 0, count: y.count)
        for j in 1...y.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[y.count]
}
/// OCR hatası (ör. baştaki harfin düşmesi) olsa da adı rehberdeki kişiyle eşleştirir
func fuzzyMatches(_ query: String, _ candidate: String) -> Bool {
    let q = normName(query), c = normName(candidate)
    guard q.count >= 4, !c.isEmpty else { return false }
    if q == c { return true }
    if c.hasSuffix(q) || q.hasSuffix(c) { return min(q.count, c.count) >= 5 }   // "ehmettahca" ~ "mehmettahca"
    let d = editDistance(q, c)
    return d <= max(1, min(q.count, c.count) / 6)
}

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
                out.firstName = c.givenName.split(separator: " ").first.map(String.init) ?? ""
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
            if matches.isEmpty {
                // OCR hatası olabilir: adı bulanık eşleştir
                let req = CNContactFetchRequest(keysToFetch: keys)
                var found: [CNContact] = []
                try store.enumerateContacts(with: req) { c, _ in
                    let full = "\(c.givenName) \(c.familyName)"
                    if fuzzyMatches(info.name, full) || fuzzyMatches(info.name, c.nickname) { found.append(c) }
                }
                if found.count == 1 { matches = found; logLine("Rehber: ad bulanık eşleşti (\(info.name) → \(found[0].givenName) \(found[0].familyName))") }
            }
            if let c = matches.first {
                out.inContacts = true
                out.firstName = c.givenName.split(separator: " ").first.map(String.init) ?? ""
                if out.number.isEmpty, let p = c.phoneNumbers.first?.value.stringValue { out.number = p }
                let fn = fullName(c)
                if !fn.isEmpty && fn.lowercased() != info.name.lowercased() {
                    out.name = fuzzyMatches(info.name, fn) ? fn : "\(info.name) (\(fn))"   // OCR'ın bozduğu adı rehberdeki doğru adla değiştir
                }
            }
        }
    } catch {
        logLine("Rehber araması başarısız: \(error)")
    }
    return out
}

func writeCallerFile(_ info: CallerInfo, to dir: URL) {
    let dict: [String: Any] = ["name": info.name, "number": info.number, "in_contacts": info.inContacts, "first_name": info.firstName]
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
        try? data.write(to: dir.appendingPathComponent("caller.json"))
    }
    logLine("Arayan: ad='\(info.name)' numara='\(info.number)' rehberde=\(info.inContacts)")
}

// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate {
    var projectDir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Claude/Asistan")  // kullanıcı verisi
    var resDir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Claude/Asistan")      // agent.py, sesler/, setup.sh
    var devMode = false
    var setupController: SetupController?
    var statusItem: NSStatusItem!
    var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var autoItem: NSMenuItem!
    var lastNoteItem: NSMenuItem!
    var panel: NSPanel!
    var panelTitle: NSTextField!
    var answerButton: NSButton!

    var agent: Process?
    var agentReady = false
    var inSession = false
    var busy = false           // asistanla cevaplanan bir arama sürüyor
    var answered = false       // bu bildirim için cevap verildi (kendimiz ya da kullanıcı)
    var dismissed = false      // kullanıcı paneli kapattı
    var missing = 0
    var bannerLogged = false
    var liveWindow: NSWindow!
    var liveText: NSTextView!
    var showLive = (UserDefaults.standard.object(forKey: "showLive") as? Bool) ?? true
    var liveItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var agentRestartPending = false
    var agentRestartTimes: [Date] = []
    var quitting = false
    var manualRestart = false
    var noteField: NSTextField!
    var agentInput: FileHandle?
    var lastTextCount = -1
    var bannerTexts: [String] = []
    var bannerSource = "FaceTime"
    var outBuffer = ""
    var lastNotePath: String?
    var callSource = "FaceTime"        // asistanın cevapladığı aramanın kaynağı (FaceTime | WhatsApp)
    var bridgeOn = false               // Devral / normal arama için mikrofon köprüsü (fiziksel mikrofon -> Asistan Ses Çıkışı)
    var bridgeSawCall = false
    var bridgeIdleChecks = 0
    var bridgeItem: NSMenuItem!
    var autoMode = UserDefaults.standard.bool(forKey: "autoMode")
    // Rahatsız Etme (Odak) açıkken gelen aramayı onay beklemeden asistanla cevapla (varsayılan: açık)
    var dndAuto: Bool = (UserDefaults.standard.object(forKey: "dndAuto") as? Bool) ?? true
    var dndItem: NSMenuItem!
    var dndLastState: Bool? = nil
    var dndLastCheck = Date.distantPast
    var dndCached = false
    // Duraklat: açıkken gelen aramalar karşılanmaz (panel de çıkmaz)
    var paused = UserDefaults.standard.bool(forKey: "paused")
    var pauseItem: NSMenuItem!
    var takeItem: NSMenuItem?
    var endItem: NSMenuItem?
    var liveEndBtn: NSButton?
    var liveTakeBtn: NSButton?
    var liveSendBtn: NSButton?
    var sessionStartedAt: Date?
    var sessionCaller = ""
    var modeCache: (Date, String) = (.distantPast, "")
    lazy var mobile = MobileBridge()   // canlı metni iPhone'daki Asistan Canlı uygulamasına yayınlar
    var mobileItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        resolveProjectDir()
        openLog()
        logLine("Uygulama başladı. Klasör: \(projectDir.path)")
        if !devMode && !isInApplications() && offerInstallToApplications() { return }
        installDefaultListeners()

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            logLine("Erişilebilirlik izni yok — Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik")
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in logLine("Mikrofon izni: \(ok)") }
        CNContactStore().requestAccess(for: .contacts) { ok, _ in logLine("Rehber izni: \(ok)") }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let mainMenu = NSMenu()
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
        mobile.onNote = { [weak self] t in self?.deliverNote(t, fromPhone: true) }
        mobile.onEnd = { [weak self] in self?.endSession() }
        mobile.onClientsChanged = { [weak self] in self?.refreshMobileItem() }
        let st = setupStatus()
        if st.audio && st.py && st.key { startAgent() } else { showSetup() }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        updateStatus()
    }

    func applicationWillTerminate(_ n: Notification) {
        quitting = true
        agent?.terminate()
    }

    func isInApplications() -> Bool {
        let p = Bundle.main.bundleURL.path
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// İlk kurulum: uygulama Uygulamalar dışında çalışıyorsa (İndirilenler, Masaüstü, disk görüntüsü) oraya kopyalayıp oradan başlat.
    /// true döndürürse uygulama kapanıyor (kopyadan yeniden açılıyor).
    func offerInstallToApplications() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Asistan Uygulamalar klasörüne kurulsun mu?"
        a.informativeText = "Uygulama şu an Uygulamalar klasörünün dışında çalışıyor. Kurarsan Launchpad ve Spotlight'tan açabilirsin."
        a.addButton(withTitle: "Uygulamalar'a kur")
        a.addButton(withTitle: "Burada çalıştır")
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        let dest = URL(fileURLWithPath: "/Applications/Asistan.app")
        func run(_ tool: String, _ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try? p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        try? FileManager.default.removeItem(at: dest)
        var ok = run("/usr/bin/ditto", [Bundle.main.bundleURL.path, dest.path]) == 0
        if !ok {   // /Applications yazılamıyorsa kullanıcının kendi Applications klasörü
            let home = URL(fileURLWithPath: NSHomeDirectory() + "/Applications")
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let d2 = home.appendingPathComponent("Asistan.app")
            try? FileManager.default.removeItem(at: d2)
            ok = run("/usr/bin/ditto", [Bundle.main.bundleURL.path, d2.path]) == 0
            if ok { _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", d2.path]); return launchCopy(d2) }
        }
        if ok {
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
            return launchCopy(dest)
        }
        let e = NSAlert()
        e.messageText = "Kopyalanamadı"
        e.informativeText = "Uygulamayı elle Uygulamalar klasörüne sürükleyebilirsin. Şimdilik bulunduğu yerden çalışıyor."
        e.runModal()
        return false
    }

    func launchCopy(_ url: URL) -> Bool {
        logLine("Uygulamalar'a kuruldu: \(url.path)")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    func resolveProjectDir() {
        // /Applications'taki kısayol (symlink) olsa bile gerçek konumuna bak
        let bundleParent = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: bundleParent.appendingPathComponent("agent.py").path) {
            // Geliştirme: uygulama, agent.py ile aynı klasörde
            projectDir = bundleParent
            resDir = bundleParent
            devMode = true
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Asistan")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        projectDir = support
        resDir = Bundle.main.resourceURL ?? support
    }

    /// Kurulum durumu: (Loopback aygıtları, Python ortamı, API anahtarı, izinler)
    /// .env'i okur (değerler yalnızca bellekte kullanılır; gizli anahtarlar hiçbir yere yazdırılmaz)
    func readEnv() -> [String: String] {
        var out: [String: String] = [:]
        guard let txt = try? String(contentsOf: projectDir.appendingPathComponent(".env"), encoding: .utf8) else { return out }
        for raw in txt.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// .env'de verilen anahtarları günceller (nil = sil); diğer satırlara dokunmaz, izinleri 600 yapar
    @discardableResult
    func updateEnv(_ changes: [String: String?]) -> Bool {
        let url = projectDir.appendingPathComponent(".env")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        for (k, v) in changes {
            lines.removeAll { $0.hasPrefix(k + "=") }
            if let v = v, !v.isEmpty { lines.append(k + "=" + v.replacingOccurrences(of: "\n", with: " ")) }
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            logLine("Ayarlar kaydedildi (.env): \(changes.keys.sorted().joined(separator: ", "))")
            return true
        } catch {
            logLine(".env yazılamadı: \(error)")
            return false
        }
    }

    /// Seçili sağlayıcının API anahtarı girilmiş mi?
    func hasProviderKey(_ env: [String: String]? = nil) -> Bool {
        let e = env ?? readEnv()
        let provider = (e["LLM_PROVIDER"] ?? "anthropic").lowercased()
        let convMode = (e["CONVERSATION_MODE"] ?? "classic").lowercased()
        if (convMode == "realtime" || convMode == "live") && (e["OPENAI_API_KEY"] ?? "").count <= 20 { return false }
        if provider == "ollama" { return true }
        let key = provider == "openai" ? (e["OPENAI_API_KEY"] ?? "") : (e["ANTHROPIC_API_KEY"] ?? "")
        return key.count > 20
    }

    var assistantPrefs: AssistantPrefsController?
    var instructions: InstructionsController?
    @objc func showInstructions() {
        if instructions == nil { instructions = InstructionsController(app: self) }
        instructions?.show()
    }
    @objc func showAssistantPrefs() {
        if assistantPrefs == nil { assistantPrefs = AssistantPrefsController(app: self) }
        assistantPrefs?.show()
    }

    func setupStatus() -> (audio: Bool, py: Bool, key: Bool, perms: Bool) {
        let audio = loopbackAudioReady()
        let fm = FileManager.default
        let pyExe = fm.isExecutableFile(atPath: projectDir.appendingPathComponent(".venv/bin/python").path)
        let py = pyExe && (devMode || fm.fileExists(atPath: projectDir.appendingPathComponent(".deps_ok").path))
        let key = hasProviderKey()
        let perms = AXIsProcessTrusted()
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && CNContactStore.authorizationStatus(for: .contacts) == .authorized
        return (audio, py, key, perms)
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
            let previous = path + ".previous"      // bir önceki günlük bir tur saklanır
            try? FileManager.default.removeItem(atPath: previous)
            try? FileManager.default.moveItem(atPath: path, toPath: previous)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous)
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
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
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self
            menu.addItem(it)
            return it
        }
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        func addTo(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self
            m.addItem(it)
            return it
        }
        pauseItem = add("Arama karşılamayı duraklat", #selector(togglePaused), "p")
        pauseItem.state = paused ? .on : .off
        autoItem = add("Gelen aramayı otomatik asistanla cevapla", #selector(toggleAuto))
        autoItem.state = autoMode ? .on : .off
        dndItem = add("Rahatsız Etme açıkken otomatik cevapla", #selector(toggleDndAuto))
        dndItem.state = dndAuto ? .on : .off
        menu.addItem(.separator())
        _ = add("Canlı metin penceresini aç", #selector(openLiveWindow), "l")
        mobileItem = add("iPhone'dan izle…", #selector(showMobileBridge))
        refreshMobileItem()
        takeItem = add("Görüşmeyi devral (asistan çıkar)", #selector(takeOver), "d")
        endItem = add("Görüşmeyi sonlandır (asistan susar)", #selector(endSession), "e")
        menu.addItem(.separator())
        lastNoteItem = add("Son notu aç", #selector(openLastNote))
        lastNoteItem.isEnabled = false
        _ = add("Notlar klasörünü aç", #selector(openNotesFolder))
        menu.addItem(.separator())
        _ = add("Talimatlar… (bugünün durumu, kurallar)", #selector(showInstructions), "t")
        _ = add("Asistan ayarları… (mod, model, API, karşılama)", #selector(showAssistantPrefs), ",")
        _ = add("Ses ayarları…", #selector(showSoundPrefs))
        _ = add("Kurulum ve izinleri kontrol et…", #selector(showSetup))
        let advancedItem = NSMenuItem(title: "Diğer seçenekler", action: nil, keyEquivalent: "")
        let advanced = NSMenu()
        advanced.autoenablesItems = false
        liveItem = addTo(advanced, "Görüşme sırasında canlı metni göster", #selector(toggleLive))
        liveItem.state = showLive ? .on : .off
        bridgeItem = addTo(advanced, "Mikrofonumu aramaya aktar (normal arama, köprü)", #selector(toggleBridge), "m")
        loginItem = addTo(advanced, "Oturum açılışında başlat", #selector(toggleLogin))
        refreshLoginItem()
        advanced.addItem(.separator())
        _ = addTo(advanced, "Kayıt dosyasını aç (app.log)", #selector(openLogFile))
        _ = addTo(advanced, "Tanı: 5 sn sonra bildirim/WhatsApp ağacını kaydet", #selector(dumpDiag))
        _ = addTo(advanced, "Asistanı yeniden başlat", #selector(restartAgent))
        advancedItem.submenu = advanced
        menu.addItem(advancedItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func togglePaused() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: "paused")
        pauseItem.state = paused ? .on : .off
        if paused { hidePanel() }
        logLine("Arama karşılama: \(paused ? "DURAKLATILDI" : "devam ediyor")")
        updateStatus()
    }

    /// Durum satırında gösterilen kısa mod/model özeti (.env'den, 5 sn önbellekli)
    func modeSummary() -> String {
        if Date().timeIntervalSince(modeCache.0) < 5 { return modeCache.1 }
        let e = readEnv()
        let llm = e["LLM_MODEL"] ?? e["CLAUDE_MODEL"] ?? "claude-haiku-4-5"
        let mode = (e["CONVERSATION_MODE"] ?? "classic").lowercased()
        let text: String
        switch mode {
        case "live": text = "GPT-Live (\(e["LIVE_MODEL"] ?? "gpt-live-1")) · arka uç \(llm)"
        case "realtime": text = "Realtime (\(e["RT_MODEL"] ?? "gpt-realtime")) · özet \(llm)"
        default: text = "klasik · \(llm)"
        }
        modeCache = (Date(), text)
        return text
    }

    /// Canlı pencerenin başlığı (arayan + süre) ve düğmelerin etkinliği
    func refreshLiveChrome() {
        liveEndBtn?.isEnabled = inSession
        liveTakeBtn?.isEnabled = inSession
        liveSendBtn?.isEnabled = inSession
        noteField?.isEnabled = inSession
        guard let w = liveWindow else { return }
        var title = "Canlı görüşme"
        if inSession, let t0 = sessionStartedAt {
            let sec = Int(Date().timeIntervalSince(t0))
            let ss = sec % 60
            title += " — " + (sessionCaller.isEmpty ? "arayan" : sessionCaller) + " · \(sec / 60):" + (ss < 10 ? "0" : "") + "\(ss)"
        }
        if w.title != title { w.title = title }
        mobile.setState(inSession: inSession, caller: sessionCaller, startedAt: sessionStartedAt, status: statusLine.title)
    }

    func updateStatus() {
        var text: String
        if agent == nil || !(agent?.isRunning ?? false) { text = agentRestartPending ? "Asistan durdu — yeniden başlatılıyor…" : "Asistan çalışmıyor" }
        else if !agentReady && !inSession { text = "Asistan yükleniyor…" }
        else if inSession { text = "Görüşmede (asistan konuşuyor)" }
        else if busy { text = "Arama cevaplanıyor…" }
        else if paused { text = "Duraklatıldı — aramalar karşılanmıyor" }
        else { text = "Hazır — " + modeSummary() }
        statusLine.title = text
        endItem?.isEnabled = inSession
        takeItem?.isEnabled = inSession
        statusItem.button?.title = inSession ? " Görüşmede" : ""
        let symbol = inSession ? "phone.circle.fill" : (busy ? "phone.arrow.down.left" : (agentReady ? "phone.circle" : "phone.badge.waveform"))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Asistan") ?? NSImage(systemSymbolName: "phone.circle", accessibilityDescription: "Asistan") {
            statusItem.button?.image = img
        }
        lastNoteItem.isEnabled = lastNotePath != nil
    }

    @objc func toggleDndAuto() {
        dndAuto.toggle()
        UserDefaults.standard.set(dndAuto, forKey: "dndAuto")
        dndItem.state = dndAuto ? .on : .off
        dndLastCheck = .distantPast
        logLine("Rahatsız Etme'de otomatik cevap: \(dndAuto ? "açık" : "kapalı") (şu an Odak: \(isDoNotDisturbOn() ? "açık" : "kapalı"))")
    }

    /// Mac'te herhangi bir Odak modu (Rahatsız Etme dahil) etkin mi? ~/Library/DoNotDisturb/DB/Assertions.json okunur
    /// (Tam Disk Erişimi gerekebilir). 2 sn önbellek.
    func isDoNotDisturbOn() -> Bool {
        if Date().timeIntervalSince(dndLastCheck) < 2 { return dndCached }
        dndLastCheck = Date()
        var on = false
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["data"] as? [[String: Any]] {
            for d in arr {
                if let recs = d["storeAssertionRecords"] as? [Any], !recs.isEmpty { on = true; break }
            }
        } else if dndLastState == nil {
            logLine("Odak durumu okunamadı (Assertions.json). Sistem Ayarları > Gizlilik ve Güvenlik > Tam Disk Erişimi'nde Asistan'a izin verin.")
        }
        if dndLastState != on { logLine("Odak/Rahatsız Etme durumu: \(on ? "AÇIK" : "kapalı")"); dndLastState = on }
        dndCached = on
        return on
    }

    @objc func toggleAuto() {
        autoMode.toggle()
        UserDefaults.standard.set(autoMode, forKey: "autoMode")
        autoItem.state = autoMode ? .on : .off
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
    @objc func openNotesFolder() { NSWorkspace.shared.open(projectDir.appendingPathComponent("notlar")) }
    @objc func openLogFile() { openInTextEdit(projectDir.appendingPathComponent("app.log")) }
    @objc func restartAgent() {
        manualRestart = true
        agent?.terminate()
        agentReady = false
        inSession = false
        busy = false
        bridgeOn = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.startAgent() }
    }


    // MARK: Canlı görüşme metni

    func buildLiveWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Canlı görüşme"
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces]
        let cb = w.contentView!.bounds
        let sv = NSScrollView(frame: NSRect(x: 0, y: 48, width: cb.width, height: cb.height - 48))
        sv.hasVerticalScroller = true
        sv.autoresizingMask = [.width, .height]

        let field = NSTextField(frame: NSRect(x: 10, y: 12, width: cb.width - 290, height: 26))
        field.placeholderString = "Asistana talimat yaz (Enter ile gönder)"
        field.autoresizingMask = [.width]
        field.target = self
        field.action = #selector(sendNote)
        w.contentView!.addSubview(field)
        noteField = field
        let send = NSButton(title: "Gönder", target: self, action: #selector(sendNote))
        send.bezelStyle = .rounded
        send.frame = NSRect(x: cb.width - 92, y: 10, width: 82, height: 30)
        send.autoresizingMask = [.minXMargin]
        w.contentView!.addSubview(send)
        liveSendBtn = send
        let endBtn = NSButton(title: "Sonlandır", target: self, action: #selector(endSession))
        endBtn.bezelStyle = .rounded
        endBtn.frame = NSRect(x: cb.width - 272, y: 10, width: 82, height: 30)
        endBtn.autoresizingMask = [.minXMargin]
        w.contentView!.addSubview(endBtn)
        liveEndBtn = endBtn
        let take = NSButton(title: "Devral", target: self, action: #selector(takeOver))
        take.bezelStyle = .rounded
        take.bezelColor = .systemOrange
        take.frame = NSRect(x: cb.width - 182, y: 10, width: 82, height: 30)
        take.autoresizingMask = [.minXMargin]
        w.contentView!.addSubview(take)
        liveTakeBtn = take
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
            w.setFrameOrigin(NSPoint(x: f.maxX - 460, y: f.maxY - 540))
        }
        liveWindow = w
        liveText = tv
    }

    func appendLive(_ speaker: String, _ text: String, color: NSColor) {
        let a = NSMutableAttributedString()
        a.append(NSAttributedString(string: speaker + ": ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: color]))
        a.append(NSAttributedString(string: text + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        liveText.textStorage?.append(a)
        liveText.scrollToEndOfDocument(nil)
        let kind = color == .systemBlue ? "caller" : color == .systemOrange ? "interrupted" : color == .systemPurple ? "you" : "assistant"
        mobile.append(kind: kind, speaker: speaker, text: text)
    }

    func appendLiveNote(_ text: String) {
        liveText.textStorage?.append(NSAttributedString(string: text + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        liveText.scrollToEndOfDocument(nil)
        mobile.append(kind: "note", speaker: "", text: text)
    }

    /// Yazılan notu çalışan ajana iletir; ajan bunu konuşmanın akışında arayana söyler
    @objc func sendNote() {
        if deliverNote(noteField.stringValue) { noteField.stringValue = "" }
    }

    /// Notu ajana iletir (Mac penceresinden ya da iPhone'dan); gönderildiyse true
    @discardableResult
    func deliverNote(_ raw: String, fromPhone: Bool = false) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard inSession else {
            appendLiveNote("Not gönderilemedi: şu an görüşme yok.")
            return false
        }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        if let data = ("NOT:" + oneLine + "\n").data(using: .utf8) {
            try? agentInput?.write(contentsOf: data)
        }
        appendLive("Senin talimatın", oneLine + "  (asistana talimat olarak gönderildi" + (fromPhone ? ", iPhone'dan)" : ")"), color: .systemPurple)
        logLine("Not gönderildi\(fromPhone ? " (iPhone)" : ""): \(oneLine)")
        return true
    }

    /// Görüşmeyi devral: asistan kısa bir geçiş cümlesi söyler, çıkar; ses cihazları eski haline döner, arama açık kalır
    var tookOver = false
    var callGoneTicks = 0

    /// Oturumu sonlandır: asistan susar, not kaydedilir; aramayı kapatmaz
    @objc func endSession() {
        guard inSession else { appendLiveNote("Sonlandırılamadı: şu an asistanlı görüşme yok."); return }
        if let data = "BITIR\n".data(using: .utf8) { try? agentInput?.write(contentsOf: data) }
        appendLiveNote("— Görüşme sonlandırılıyor —")
        logLine("Oturum sonlandırma istendi")
    }

    /// Arama kapandı mı? Bildirim arayüzü kayboldu ve çağrı sesi sürecinde ses yok
    func detectCallEnded(incoming: Bool) {
        guard inSession else { callGoneTicks = 0; return }
        if incoming { callGoneTicks = 0; return }
        callGoneTicks += 1
        guard callGoneTicks >= 20, callGoneTicks % 5 == 0 else { return }   // ~8 sn
        let rep = audioProcessReport()
        if rep.contains("avconferenced") || rep.contains("mobilephone") || rep.contains("FaceTime") || rep.contains("telephony") || rep.contains("WhatsApp") { return }
        logLine("Arama kapanmış görünüyor (bildirim yok, çağrı sesi yok); oturum sonlandırılıyor")
        callGoneTicks = 0
        endSession()
    }
    var needSystemReset = false
    /// FaceTime mikrofonunu menüden seçer (Loopback'te "Asistan Mikrofonu" ya da normal kullanım için "Sistem ayarı")
    func faceTimeSetMic(_ keys: [String], retry: Int = 0, openIfClosed: Bool = true) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FaceTime").isEmpty {
            guard openIfClosed, retry < 3 else { return }
            // FaceTime kapalıyken menüye ulaşılamaz: arka planda aç, sonra seç
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.hides = true
            logLine("FaceTime kapalı; arka planda açılıyor")
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/FaceTime.app"), configuration: cfg) { [weak self] _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self?.faceTimeSetMic(keys, retry: retry + 1) }
            }
            return
        }
        let a = facetimePickDevice(input: true, keys: keys)
        logLine("FaceTime mikrofon seçimi \(keys.first ?? ""): \(a)")
    }

    /// Fiziksel mikrofon adı (Devral ve köprü için): ses ayarlarındaki seçim, yoksa yerleşik mikrofon
    func humanMicName() -> String {
        (userPreferredDevice(input: true) ?? builtinDevice(input: true)).map(deviceName) ?? ""
    }

    func sendAgent(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) { try? agentInput?.write(contentsOf: data) }
    }

    /// Normal (asistansız) aramada mikrofonu Asistan Mikrofonu hattına aktarır / kapatır
    @objc func toggleBridge() {
        guard agentReady || bridgeOn else { notify("Köprü açılamadı", "Asistan henüz hazır değil."); return }
        if bridgeOn {
            sendAgent("KOPRU_KAPAT")
        } else {
            guard !inSession else { appendLiveNote("Asistan konuşurken köprü açılmaz; önce Devral'ı kullanın."); return }
            guard loopbackAudioReady() else { notify("Loopback hazır değil", "Asistan Dinleme, Mikrofonu ve Ses Çıkışı aygıtları açık olmalı."); return }
            bridgeSawCall = false; bridgeIdleChecks = 0
            sendAgent("KOPRU_AC:" + humanMicName())
        }
    }

    /// Köprü açıkken arama bittiyse köprüyü kapat (mikrofon göstergesi açık kalmasın)
    func watchBridge() {
        guard bridgeOn, !inSession, guardTicks % 5 == 0 else { return }
        let rep = audioProcessReport()
        let active = ["avconferenced", "mobilephone", "FaceTime", "telephony", "WhatsApp", "whatsapp"].contains { rep.contains($0) }
        if active { bridgeSawCall = true; bridgeIdleChecks = 0; return }
        guard bridgeSawCall else { return }
        bridgeIdleChecks += 1
        if bridgeIdleChecks >= 4 {
            logLine("Arama bitmiş görünüyor; mikrofon köprüsü kapatılıyor")
            sendAgent("KOPRU_KAPAT")
            bridgeSawCall = false; bridgeIdleChecks = 0
        }
    }

    @objc func takeOver() {
        guard inSession else {
            appendLiveNote("Devralınamadı: şu an asistanlı görüşme yok.")
            return
        }
        tookOver = true
        sendAgent("DEVRAL:" + humanMicName())
        appendLiveNote("— Devralıyorsun: asistan çıkıyor, mikrofonun aynı hatta aktarılıyor —")
        logLine("Devral istendi")
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
            notify("Onay gerekiyor", "Sistem Ayarları > Genel > Oturum Açma Öğeleri'nden Asistan'a izin ver.")
        }
        refreshLoginItem()
    }

    var soundPrefs: SoundPrefsController?
    @objc func showSoundPrefs() {
        if soundPrefs == nil { soundPrefs = SoundPrefsController() }
        soundPrefs?.show()
    }

    @objc func dumpDiag() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            let u = self.projectDir.appendingPathComponent("tani.txt")
            logLine("Tanı: ses kullanan süreçler: \(audioProcessReport())")
            dumpTree(bundleIDs: ["com.apple.notificationcenterui", "net.whatsapp.WhatsApp", "desktop.WhatsApp"], to: u)
            logLine("Tanı yazıldı: \(u.path)")
        }
    }

    @objc func toggleLive() {
        showLive.toggle()
        UserDefaults.standard.set(showLive, forKey: "showLive")
        liveItem.state = showLive ? .on : .off
    }
    @objc func openLiveWindow() { liveWindow.orderFrontRegardless() }

    func refreshMobileItem() {
        guard let it = mobileItem else { return }
        it.state = mobile.enabled ? .on : .off
        let n = mobile.clientCount
        it.title = "iPhone'dan izle…" + (mobile.enabled && n > 0 ? " (\(n) cihaz bağlı)" : "")
    }

    /// iPhone köprüsü: aç/kapat, eşleştirme kodunu göster/yenile
    @objc func showMobileBridge() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "iPhone'dan canlı metni izle"
        if mobile.enabled {
            a.informativeText = "Açık. iPhone'da Asistan Canlı uygulamasını açın; Mac aynı Wi-Fi ağında otomatik bulunur.\n\n"
                + "Eşleştirme kodu:  \(mobile.displayCode)\n\n"
                + "Bağlı cihaz: \(mobile.clientCount). Bağlantı bu kodla şifrelenir; kodu yenilerseniz bağlı cihazların kodu yeniden girmesi gerekir."
            a.addButton(withTitle: "Tamam")
            a.addButton(withTitle: "Kapat (yayını durdur)")
            a.addButton(withTitle: "Yeni kod üret")
        } else {
            a.informativeText = "Açtığınızda görüşmenin canlı metni yerel ağdaki iPhone'unuza (Asistan Canlı uygulaması) şifreli olarak gönderilir. "
                + "iPhone'dan asistana talimat yazabilir ve görüşmeyi sonlandırabilirsiniz.\n\nmacOS gelen bağlantılar ya da yerel ağ için izin sorabilir; izin verin."
            a.addButton(withTitle: "Aç")
            a.addButton(withTitle: "Vazgeç")
        }
        let r = a.runModal()
        if mobile.enabled {
            if r == .alertSecondButtonReturn { mobile.setEnabled(false) }
            else if r == .alertThirdButtonReturn { mobile.regenerateCode(); showMobileBridge(); return }
        } else if r == .alertFirstButtonReturn {
            mobile.setEnabled(true)
            refreshMobileItem()
            showMobileBridge()
            return
        }
        refreshMobileItem()
    }

    /// Ajan çıktısındaki satırı ("[13:58:08] ARAYAN: ...") canlı pencereye yansıtır
    func updateLive(_ line: String) {
        var msg = line
        if msg.hasPrefix("["), let r = msg.range(of: "] ") { msg = String(msg[r.upperBound...]) }
        msg = msg.trimmingCharacters(in: .whitespaces)
        if msg.contains("ARAMA OTURUMU BAŞLADI") {
            liveText.string = ""
            mobile.reset()
            if showLive { liveWindow.orderFrontRegardless() }
        } else if msg.hasPrefix("arayan: ") {
            appendLiveNote("Arayan: " + String(msg.dropFirst("arayan: ".count)))
        } else if msg.contains("karşılama çalınıyor") {
            appendLive("Asistan", "(karşılama mesajı çalınıyor)", color: .systemGreen)
        } else if msg.hasPrefix("ARAYAN: ") {
            appendLive("Arayan", String(msg.dropFirst("ARAYAN: ".count)), color: .systemBlue)
        } else if msg.hasPrefix("ASİSTAN (kesildi):") {
            appendLive("Asistan (sözü kesildi)", String(msg.dropFirst("ASİSTAN (kesildi):".count)).trimmingCharacters(in: .whitespaces), color: .systemOrange)
        } else if msg.hasPrefix("ASİSTAN: ") {
            appendLive("Asistan", String(msg.dropFirst("ASİSTAN: ".count)), color: .systemGreen)
        } else if msg.contains("OTURUM BİTTİ") {
            appendLiveNote("— Görüşme bitti —")
        }
    }

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

        answerButton = NSButton(title: "Asistanla Cevapla", target: self, action: #selector(answerWithAssistant))
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
        let ready = agentReady && !busy
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

    var guardTicks = 0
    var guardFixes = 0
    /// Arama bitince FaceTime mikrofonunu Sistem ayarına döndürür; köprü açıksa arama bitince kapatır
    func guardAudioDefaults() {
        guardTicks += 1
        watchBridge()
        // Arama bitince FaceTime mikrofonunu yeniden "Sistem ayarı"na al (normal aramalar fiziksel mikrofonla çalışsın)
        if needSystemReset && guardTicks % 5 == 0 && !busy && !inSession && !bridgeOn && missing > 6 {
            needSystemReset = false
            faceTimeSetMic(["system setting", "sistem ayar", "use system"], openIfClosed: false)
        }
    }

    var bannerDiagDone = false
    var endedByAssistant = false
    var ocrGot = false
    var ocrTries = 0

    func tick() {
        guardAudioDefaults()
        let r = scanNotifications()
        let frameOK = r.groupFrame.map { $0.width > 250 && $0.height > 60 } ?? false
        let incoming = r.button != nil || frameOK
        if incoming { missing = 0 } else { missing += 1 }
        detectCallEnded(incoming: incoming)
        if incoming && r.texts.count != lastTextCount {
            lastTextCount = r.texts.count
            logLine("BANNER METİNLERİ: " + r.texts.joined(separator: " | "))
        }
        if incoming && !bannerDiagDone && r.texts.count <= 2 {
            // Arayan etiketi okunamadı: banner ağacını bir kez dosyaya yaz (tani_banner.txt)
            bannerDiagDone = true
            let u = projectDir.appendingPathComponent("tani_banner.txt")
            dumpTree(bundleIDs: ["com.apple.notificationcenterui"], to: u)
            logLine("Banner etiketleri okunamadı; ağaç yazıldı: \(u.path)")
        }
        if incoming && !ocrGot && r.texts.count <= 2 && ocrTries < 4, let gf = r.groupFrame, gf.width > 250 {
            ocrTries += 1
            let lines = ocrBanner(frame: gf)
            logLine("Banner OCR (\(ocrTries)): " + lines.joined(separator: " | "))
            if lines.count >= 2 {
                let texts = lines.map { "OCR: \($0)" }
                bannerTexts = texts
                if enrichFromContacts(extractCaller(from: texts)).inContacts { ocrGot = true }   // rehberle eşleşmediyse yeniden okumayı dene
            }
        }
        if incoming && !ocrGot && r.texts.count >= bannerTexts.count { bannerTexts = r.texts }
        if incoming { bannerSource = r.source }
        if missing > 5 { ocrGot = false; ocrTries = 0; bannerDiagDone = false; bannerLogged = false; bannerTexts = []; lastTextCount = -1 }

        refreshLiveChrome()
        if incoming && !answered && !dismissed && !paused {
            showPanel()
            if (autoMode || (dndAuto && isDoNotDisturbOn())) && agentReady && !busy { answerWithAssistant() }
        }
        if missing >= 2 { hidePanel() }
        if missing > 5 {
            answered = false
            dismissed = false
        }
        // Bildirim kullanıcı tarafından açıldıysa (asistan olmadan) tekrar gösterme
        if !incoming && !busy { answered = answered && missing <= 5 }
    }

    /// Bildirimdeki "cevapla" düğmesine basar
    func pressAnswer() -> Bool {
        let r = scanNotifications()
        if let b = r.button {
            let ok = AXUIElementPerformAction(b, r.action as CFString) == .success
            logLine("Cevapla düğmesine basıldı (AX): \(ok)")
            return ok
        }
        if let fr = r.groupFrame, fr.width > 250, fr.height > 60 {
            let rel = fr.height > 250 ? largeRel : compactRel
            let pt = CGPoint(x: fr.minX + fr.width * rel.x, y: fr.minY + fr.height * rel.y)
            clickAt(pt)
            logLine("Cevapla düğmesine tıklandı (koordinat): \(pt)")
            return true
        }
        return false
    }

    func fireAgentFlag() {
        FileManager.default.createFile(atPath: projectDir.appendingPathComponent("go.flag").path, contents: Data())
        logLine("Ajan tetiklendi (go.flag)")
    }

    /// Arama cevaplandıktan sonra banner'daki arayan adını (en çok ~2 sn) bekler, caller.json'u güncelleyip ajanı tetikler
    func triggerAgentWhenCallerKnown(attempt: Int = 0) {
        guard busy else { return }
        let r = scanNotifications()
        let info = extractCaller(from: r.texts)
        if !info.name.isEmpty || !info.number.isEmpty {
            bannerTexts = r.texts
            let full = enrichFromContacts(info)
            writeCallerFile(full, to: projectDir)
            logLine("Arayan cevaplandıktan sonra okundu: ad='\(full.name)' numara='\(full.number)' rehberde=\(full.inContacts)")
            fireAgentFlag()
            return
        }
        if attempt >= 8 {
            logLine("Arayan adı cevaplandıktan sonra da okunamadı; ajan adsız başlatılıyor")
            fireAgentFlag()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.triggerAgentWhenCallerKnown(attempt: attempt + 1) }
    }

    /// Asistan görüşmeyi bitirdiğinde aramayı kapat; kapat düğmesi arayüzde birkaç saniye geç belirebildiği için tekrar dener
    func hangUpWithRetries(attempt: Int = 0) {
        let wa = callSource == "WhatsApp"
        var who = hangUpCall(whatsapp: wa)
        if who.isEmpty && attempt >= 3 && !wa && hangUpByRedButton() { who = "kırmızı düğme" }
        if !who.isEmpty {
            logLine("Otomatik kapatma: arama kapatıldı (\(who))")
        } else if attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.hangUpWithRetries(attempt: attempt + 1) }
        } else {
            logLine("Otomatik kapatma: bitir düğmesi bulunamadı (arama açık kalabilir)")
        }
    }

    @objc func answerWithAssistant() {
        guard agentReady, !busy else { return }
        guard loopbackAudioReady() else {
            answered = true   // bu arama için tekrar tekrar uyarma
            let st = loopbackStatus()
            logLine("Loopback aygıtları hazır değil (dinleme=\(st.listen), mikrofon=\(st.mic), çıkış=\(st.playback)); arama cevaplanmadı")
            notify("Arama asistanla cevaplanamadı", "Loopback'te Asistan Dinleme, Asistan Mikrofonu ve Asistan Ses Çıkışı aygıtlarını açın.")
            return
        }
        if bridgeOn { sendAgent("KOPRU_KAPAT"); bridgeOn = false }
        busy = true
        answered = true
        hidePanel()
        updateStatus()
        callSource = bannerSource
        writeCallerFile(enrichFromContacts(extractCaller(from: bannerTexts)), to: projectDir)
        // FaceTime: mikrofon olarak Asistan Mikrofonu'nu seç (sistem varsayılanı değişmez). WhatsApp'ta bu seçim bir kez elle yapılır.
        if callSource == "FaceTime" {
            faceTimeSetMic(["asistan mikrofonu"])
            needSystemReset = true
        }
        let settle: Double = callSource == "WhatsApp" ? 0.3 : 0.6
        logLine("Arama kaynağı: \(callSource); Loopback hattı (sistem ses ayarı değişmedi); \(settle) sn sonra cevaplanıyor")
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self = self else { return }
            if self.pressAnswer() {
                let initial = extractCaller(from: self.bannerTexts)
                if initial.name.isEmpty && initial.number.isEmpty {
                    // Çalarken banner'dan ad okunamadı: cevaplanınca banner "Ad, FaceTime Audio - 0:02" diye ad gösteriyor; bunu bekle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.triggerAgentWhenCallerKnown() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.fireAgentFlag() }
                }
                // Ajan 20 sn içinde başlamazsa geri al
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self = self, self.busy, !self.inSession else { return }
                    logLine("Ajan başlamadı, geri alınıyor")
                    self.busy = false
                    self.updateStatus()
                }
            } else {
                logLine("Cevapla düğmesi bulunamadı")
                self.busy = false
                self.answered = false
                self.notify("Arama cevaplanamadı", "Bildirimdeki cevapla düğmesi bulunamadı.")
                self.updateStatus()
            }
        }
    }

    // MARK: Python ajanı

    /// Daha önce çökmüş bir uygulamadan kalan ajan süreçlerini kapat (aynı anda iki ajan aramaya girmesin)
    func killOrphanAgents() {
        let script = resDir.appendingPathComponent("agent.py").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", script]
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus == 0 { logLine("Eski ajan süreci kapatıldı: \(script)") }
    }

    func startAgent() {
        killOrphanAgents()
        let py = projectDir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: py.path) else {
            logLine("Python bulunamadı: \(py.path)")
            updateStatus()
            return
        }
        let p = Process()
        p.executableURL = py
        p.arguments = ["-u", resDir.appendingPathComponent("agent.py").path]
        p.currentDirectoryURL = projectDir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["ASISTAN_HOME"] = projectDir.path
        p.environment = env
        let inPipe = Pipe()
        p.standardInput = inPipe
        agentInput = inPipe.fileHandleForWriting
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                logLine("Ajan sonlandı")
                self.agentReady = false
                self.inSession = false
                self.busy = false
                self.bridgeOn = false
                if !self.quitting && !self.manualRestart {
                    // Son 10 dakikada 5'ten fazla çöktüyse pes et; yoksa 5 sn sonra yeniden başlat
                    self.agentRestartTimes = self.agentRestartTimes.filter { Date().timeIntervalSince($0) < 600 }
                    if self.agentRestartTimes.count >= 5 {
                        logLine("Ajan tekrar tekrar çöküyor; otomatik yeniden başlatma durduruldu")
                        self.notify("Asistan durdu", "Ajan art arda çöktü. Menüden 'Asistanı yeniden başlat' ya da app.log'a bak.")
                    } else {
                        self.agentRestartTimes.append(Date())
                        self.agentRestartPending = true
                        self.notify("Asistan yeniden başlatılıyor", "Ajan beklenmedik şekilde kapandı.")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                            guard let self = self else { return }
                            self.agentRestartPending = false
                            self.startAgent()
                        }
                    }
                }
                self.manualRestart = false
                self.updateStatus()
            }
        }
        do {
            try p.run()
            agent = p
            agentReady = false
            logLine("Ajan başlatıldı (pid \(p.processIdentifier))")
        } catch {
            logLine("Ajan başlatılamadı: \(error)")
        }
        updateStatus()
    }

    func consume(_ chunk: String) {
        outBuffer += chunk
        while let r = outBuffer.range(of: "\n") {
            let line = String(outBuffer[outBuffer.startIndex..<r.lowerBound])
            outBuffer.removeSubrange(outBuffer.startIndex..<r.upperBound)
            handleLine(line)
        }
    }

    func handleLine(_ line: String) {
        logLine("agent: \(line)")
        updateLive(line)
        if let r = line.range(of: "   arayan: ") {
            var who = String(line[r.upperBound...])
            if let d = who.range(of: " - ") { who = String(who[..<d.lowerBound]) }
            if let d = who.range(of: " (") { who = String(who[..<d.lowerBound]) }
            sessionCaller = who.trimmingCharacters(in: .whitespaces)
        }
        if line.contains("ARAMA OTURUMU BAŞLADI") {
            inSession = true
            sessionStartedAt = Date()
            sessionCaller = ""
            noteField?.stringValue = ""     // önceki aramadan kalan taslak taşınmasın
            lastNotePath = nil
        } else if line.contains("Not kaydedildi:") {
            if let r = line.range(of: "Not kaydedildi:") {
                lastNotePath = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        } else if line.contains("Asistan görüşmeyi bitirdi.") {
            endedByAssistant = true
        } else if line.contains("OTURUM BİTTİ") {
            inSession = false
            busy = false
            if endedByAssistant {
                endedByAssistant = false
                let auto = (readEnv()["AUTO_HANGUP"] ?? "1") != "0"
                if auto {
                    hangUpWithRetries()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                if self.tookOver {
                    self.tookOver = false
                    self.bridgeSawCall = true; self.bridgeIdleChecks = 0   // köprü arama bitince otomatik kapanır
                }
                if let p = self.lastNotePath {
                    self.notify("Arama notu kaydedildi", (p as NSString).lastPathComponent)
                }
            }
        } else if line.contains("MİKROFON KÖPRÜSÜ AÇIK") {
            bridgeOn = true
            bridgeItem?.state = .on
        } else if line.contains("MİKROFON KÖPRÜSÜ KAPALI") {
            bridgeOn = false
            bridgeItem?.state = .off
        } else if line.contains("HAZIR. Arama bekleniyor") {
            agentReady = true
        }
        updateStatus()
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Kurulum penceresi

final class SetupController: NSObject {
    let app: AppDelegate
    var window: NSWindow!
    var labels: [String: NSTextField] = [:]
    var logView: NSTextView!
    var keyField: NSSecureTextField!
    var installButton: NSButton!
    var finishButton: NSButton!
    var timer: Timer?
    var installing = false

    init(app: AppDelegate) {
        self.app = app
        super.init()
        build()
    }

    func makeLabel(_ text: String, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        l.isSelectable = true
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = 540
        return l
    }

    func makeButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        return b
    }

    func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Asistan — Kurulum"
        w.isReleasedWhenClosed = false
        w.center()
        let cv = w.contentView!

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cv.topAnchor),
        ])

        stack.addArrangedSubview(makeLabel("Asistan kurulumu", bold: true, size: 17))
        for (k, t) in [("audio", "Loopback ses aygıtları"), ("py", "Python ortamı ve paketler"),
                       ("key", "Anthropic API anahtarı"), ("perms", "İzinler (Erişilebilirlik, Mikrofon, Rehber)")] {
            let l = makeLabel(t)
            labels[k] = l
            stack.addArrangedSubview(l)
        }

        stack.addArrangedSubview(makeLabel("1) Loopback (sanal ses aygıtları — Rogue Amoeba, ücretli)", bold: true))
        stack.addArrangedSubview(makeLabel("Loopback'te üç aygıt oluşturun ve ana anahtarlarını Açık yapın (ayrıntı: KURULUM.md):\n• Asistan Ses Çıkışı — Pass-Thru açık, başka kaynak yok.\n• Asistan Mikrofonu — kaynak: Asistan Ses Çıkışı (kanal 1–2).\n• Asistan Dinleme — kaynaklar: FaceTime, Telefon, WhatsApp uygulamaları (kanal 1–2); \"Mute when capturing\" açık."))
        let row1 = NSStackView(views: [makeButton("Loopback'i aç", #selector(openLoopback)),
                                       makeButton("Loopback indir (rogueamoeba.com)", #selector(openLoopbackSite))])
        row1.spacing = 8
        stack.addArrangedSubview(row1)

        stack.addArrangedSubview(makeLabel("2) Python ortamı ve paketler", bold: true))
        installButton = makeButton("Kurulumu başlat (internet gerekir)", #selector(runInstall))
        stack.addArrangedSubview(installButton)

        stack.addArrangedSubview(makeLabel("3) Anthropic API anahtarı", bold: true))
        keyField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        keyField.placeholderString = "sk-ant-…"
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let row3 = NSStackView(views: [keyField, makeButton("Kaydet", #selector(saveKey))])
        row3.spacing = 8
        stack.addArrangedSubview(row3)

        stack.addArrangedSubview(makeLabel("4) İzinler", bold: true))
        stack.addArrangedSubview(makeButton("İzinleri iste", #selector(askPerms)))

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.widthAnchor.constraint(equalToConstant: 560).isActive = true
        sv.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 150))
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        sv.documentView = tv
        logView = tv
        stack.addArrangedSubview(sv)

        finishButton = makeButton("Başlat", #selector(finish))
        finishButton.keyEquivalent = "\r"
        stack.addArrangedSubview(finishButton)

        window = w
        refresh()
    }

    func show() {
        refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func log(_ s: String) {
        logView.textStorage?.append(NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor]))
        logView.scrollToEndOfDocument(nil)
    }

    func refresh() {
        let st = app.setupStatus()
        func mark(_ ok: Bool, _ t: String) -> String { (ok ? "✅ " : "⬜️ ") + t }
        labels["audio"]?.stringValue = mark(st.audio, "Loopback ses aygıtları (Asistan Dinleme / Mikrofonu / Ses Çıkışı)")
        labels["py"]?.stringValue = mark(st.py, "Python ortamı ve paketler")
        labels["key"]?.stringValue = mark(st.key, "Anthropic API anahtarı")
        labels["perms"]?.stringValue = mark(st.perms, "İzinler (Erişilebilirlik, Mikrofon, Rehber)")
        finishButton.isEnabled = st.audio && st.py && st.key
        finishButton.title = (st.audio && st.py && st.key) ? "Başlat" : "Önce 1–3. adımları tamamla"
    }

    @objc func openLoopback() {
        let url = URL(fileURLWithPath: "/Applications/Loopback.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: "https://rogueamoeba.com/loopback/")!)
        }
    }

    @objc func openLoopbackSite() { NSWorkspace.shared.open(URL(string: "https://rogueamoeba.com/loopback/")!) }

    @objc func askPerms() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        CNContactStore().requestAccess(for: .contacts) { _, _ in }
    }

    @objc func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count > 20 else { log("API anahtarı çok kısa görünüyor.\n"); return }
        var changes: [String: String?] = ["ANTHROPIC_API_KEY": key]
        let env = app.readEnv()
        for (k, v) in ["STT_BACKEND": "mlx", "WHISPER_MODEL": "mlx-community/whisper-large-v3-turbo",
                       "VAD_THRESHOLD": "0.0015", "GREETING_DELAY_S": "2.0", "LLM_PROVIDER": "anthropic"] where env[k] == nil {
            changes[k] = v
        }
        if app.updateEnv(changes) {
            keyField.stringValue = ""
            log("API anahtarı kaydedildi. (OpenAI ya da başka model için: menü > Asistan ayarları)\n")
        } else {
            log("Kaydedilemedi; app.log'a bak.\n")
        }
        refresh()
    }

    @objc func runInstall() {
        guard !installing else { return }
        installing = true
        installButton.isEnabled = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [app.resDir.appendingPathComponent("setup.sh").path, app.projectDir.path, app.resDir.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["HOME"] = NSHomeDirectory()
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.log(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.installing = false
                self.installButton.isEnabled = true
                self.log(proc.terminationStatus == 0 ? "\n✅ Kurulum tamamlandı.\n" : "\n❌ Kurulum başarısız (kod \(proc.terminationStatus)).\n")
                self.refresh()
            }
        }
        do { try p.run(); log("Kurulum başladı…\n") }
        catch { log("Başlatılamadı: \(error)\n"); installing = false; installButton.isEnabled = true }
    }

    @objc func finish() {
        let st = app.setupStatus()
        guard st.audio && st.py && st.key else { return }
        timer?.invalidate()
        window.close()
        app.startAgentIfNeeded()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()


// MARK: - Ses ayarları penceresi

final class SoundPrefsController: NSObject {
    var window: NSWindow!
    var inPopup: NSPopUpButton!
    var statusLabel: NSTextField!
    var infoLabel: NSTextField!

    func label(_ t: String, bold: Bool = false, size: CGFloat = 12) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = 480
        return l
    }

    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Ses ayarları (Loopback)"
        window.isReleasedWhenClosed = false
        let v = window.contentView!

        let h1 = label("Ses hattı: Loopback (arama sırasında sistem ses ayarı değişmez)", bold: true, size: 13)
        h1.frame = NSRect(x: 20, y: 342, width: 480, height: 18); v.addSubview(h1)
        statusLabel = label("", size: 12)
        statusLabel.frame = NSRect(x: 20, y: 252, width: 480, height: 84); v.addSubview(statusLabel)

        let sep = NSBox(frame: NSRect(x: 20, y: 242, width: 480, height: 1)); sep.boxType = .separator; v.addSubview(sep)

        let h2 = label("Ben (Devral ve mikrofon köprüsü)", bold: true, size: 13)
        h2.frame = NSRect(x: 20, y: 214, width: 480, height: 18); v.addSubview(h2)
        let l1 = label("Fiziksel mikrofonum:"); l1.frame = NSRect(x: 20, y: 184, width: 140, height: 18); v.addSubview(l1)
        inPopup = NSPopUpButton(frame: NSRect(x: 165, y: 179, width: 335, height: 26), pullsDown: false)
        inPopup.target = self; inPopup.action = #selector(changed); v.addSubview(inPopup)

        infoLabel = label("", size: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.frame = NSRect(x: 20, y: 60, width: 480, height: 110); v.addSubview(infoLabel)

        let open = NSButton(title: "Loopback'i aç", target: self, action: #selector(openLoopback))
        open.bezelStyle = .rounded
        open.frame = NSRect(x: 20, y: 18, width: 130, height: 30); v.addSubview(open)
        let refresh = NSButton(title: "Yenile", target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded
        refresh.frame = NSRect(x: 160, y: 18, width: 90, height: 30); v.addSubview(refresh)
    }

    func fill() {
        inPopup.removeAllItems()
        inPopup.addItem(withTitle: "Otomatik (yerleşik mikrofon)")
        inPopup.lastItem?.representedObject = ""
        let saved = UserDefaults.standard.string(forKey: "userInUID") ?? ""
        var selected = 0
        for d in allDevices() where hasStreams(d, input: true) {
            if nfc(deviceName(d)).hasPrefix("asistan") { continue }
            let uid = deviceUIDString(d)
            inPopup.addItem(withTitle: deviceName(d))
            inPopup.lastItem?.representedObject = uid
            if uid == saved { selected = inPopup.numberOfItems - 1 }
        }
        inPopup.selectItem(at: selected)
    }

    func updateInfo() {
        let st = loopbackStatus()
        func m(_ ok: Bool) -> String { ok ? "✅" : "⬜️" }
        statusLabel.stringValue = "\(m(st.listen)) Arayanın sesi: Asistan Dinleme\n\(m(st.playback)) Asistanın sesi: Asistan Ses Çıkışı\n\(m(st.mic)) Arama uygulamalarının mikrofonu: Asistan Mikrofonu\n\(loopbackAudioReady() ? "Hazır." : "Eksik aygıt var: Loopback'te üçünü de oluşturup Açık yapın (KURULUM.md).")"
        infoLabel.stringValue = "• FaceTime/Telefon: mikrofon arama sırasında otomatik Asistan Mikrofonu olur, arama bitince Sistem ayarına döner.\n• WhatsApp: Call → Microphone → Asistan Mikrofonu seçin (bir kez); Speaker: kendi hoparlörünüz. Normal WhatsApp aramalarında sesinizin gitmesi için menüden \"Mikrofonumu aramaya aktar\"ı kullanın ya da mikrofonu geri değiştirin.\n• Devral: asistan çıkar, fiziksel mikrofonunuz aynı hatta aktarılır."
    }

    @objc func openLoopback() {
        let url = URL(fileURLWithPath: "/Applications/Loopback.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: "https://rogueamoeba.com/loopback/")!)
        }
    }

    @objc func reload() {
        fill()
        updateInfo()
    }

    @objc func changed() {
        UserDefaults.standard.set((inPopup.selectedItem?.representedObject as? String) ?? "", forKey: "userInUID")
        logLine("Ses tercihi kaydedildi")
    }

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}



// MARK: - Talimatlar penceresi (genel kurallar + bugünün durumu)

final class InstructionsController: NSObject {
    let app: AppDelegate
    var window: NSWindow!
    var generalView: NSTextView!
    var todayView: NSTextView!
    var status: NSTextField!

    init(app: AppDelegate) { self.app = app; super.init() }

    func box(_ frame: NSRect) -> (NSScrollView, NSTextView) {
        let sv = NSScrollView(frame: frame)
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: frame.width - 20, height: frame.height))
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        sv.documentView = tv
        return (sv, tv)
    }

    func lab(_ t: String, _ y: CGFloat, bold: Bool = true) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 11)
        l.textColor = bold ? .labelColor : .secondaryLabelColor
        l.frame = NSRect(x: 20, y: y, width: 580, height: bold ? 18 : 28)
        l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 0
        return l
    }

    func build() {
        let W: CGFloat = 620
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 600),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Asistan talimatları"
        window.isReleasedWhenClosed = false
        let v = window.contentView!
        v.addSubview(lab("Genel kurallar (her aramada geçerli)", 570))
        v.addSubview(lab("Asistanın nasıl konuşacağını yaz. Örnek: \"Herkese siz diye hitap et.\"  \"Satış aramalarını nazikçe reddet, not alma.\"", 534, bold: false))
        let (s1, t1) = box(NSRect(x: 20, y: 340, width: W - 40, height: 190)); generalView = t1; v.addSubview(s1)
        v.addSubview(lab("Bugünün durumu ve kişilere özel notlar (yalnızca bugün geçerli, yarın kendiliğinden silinir)", 306))
        v.addSubview(lab("Örnek: \"Bugün 15:00'e kadar toplantıdayım, sonra dönerim.\"  \"Ahmet Bey ararsa raporun yarın hazır olacağını söyle.\"  \"Tuba Hanım'a sıcak davran, acil bir şey olursa bildirmesini söyle.\"", 270, bold: false))
        let (s2, t2) = box(NSRect(x: 20, y: 76, width: W - 40, height: 190)); todayView = t2; v.addSubview(s2)
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 52, width: W - 40, height: 16)
        v.addSubview(status)
        let save = NSButton(title: "Kaydet", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        save.frame = NSRect(x: 20, y: 14, width: 120, height: 30); v.addSubview(save)
        let close = NSButton(title: "Kapat", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 150, y: 14, width: 90, height: 30); v.addSubview(close)
        let clear = NSButton(title: "Bugünü temizle", target: self, action: #selector(clearToday))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 250, y: 14, width: 140, height: 30); v.addSubview(clear)
    }

    var generalURL: URL { app.projectDir.appendingPathComponent("talimat_genel.txt") }
    var todayURL: URL { app.projectDir.appendingPathComponent("talimat_bugun.json") }
    var todayString: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    func load() {
        generalView.string = (try? String(contentsOf: generalURL, encoding: .utf8)) ?? ""
        var today = ""
        var note = ""
        if let d = try? Data(contentsOf: todayURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if (j["date"] as? String) == todayString { today = (j["text"] as? String) ?? "" }
            else if !((j["text"] as? String) ?? "").isEmpty { note = "Dünkü not silindi (bugüne ait değildi)." }
        }
        todayView.string = today
        status.stringValue = note
    }

    @objc func saveTapped() {
        do {
            try generalView.string.trimmingCharacters(in: .whitespacesAndNewlines).write(to: generalURL, atomically: true, encoding: .utf8)
            let dict: [String: Any] = ["date": todayString, "text": todayView.string.trimmingCharacters(in: .whitespacesAndNewlines)]
            let d = try JSONSerialization.data(withJSONObject: dict)
            try d.write(to: todayURL)
            status.stringValue = "Kaydedildi. Bir sonraki aramada geçerli olur (sürmekte olan görüşme etkilenmez)."
            logLine("Talimatlar kaydedildi")
        } catch {
            status.stringValue = "Kaydedilemedi: \(error.localizedDescription)"
        }
    }

    @objc func clearToday() { todayView.string = ""; saveTapped() }
    @objc func closeTapped() { window.orderOut(nil) }

    func show() {
        if window == nil { build() }
        load()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Asistan ayarları penceresi (model, API anahtarları, ad, karşılama)

struct ModelChoice { let id: String; let label: String }

enum ModelCatalog { static let all: [String: [ModelChoice]] = [
    "anthropic": [
        ModelChoice(id: "claude-haiku-5-5", label: "Claude Haiku 5.5 — yeni, hızlı ve ucuz"),
        ModelChoice(id: "claude-haiku-4-5", label: "Claude Haiku 4.5 — hızlı, telefon için önerilen"),
        ModelChoice(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5 — daha zeki, biraz daha yavaş/pahalı"),
        ModelChoice(id: "claude-opus-5-5", label: "Claude Opus 5.5 — en güçlü; yavaş ve pahalı"),
    ],
    "openai": [
        ModelChoice(id: "gpt-4.1-mini", label: "GPT-4.1 mini — hızlı, önerilen"),
        ModelChoice(id: "gpt-4.1", label: "GPT-4.1 — daha zeki"),
        ModelChoice(id: "gpt-5-mini", label: "GPT-5 mini — yeni nesil, küçük"),
        ModelChoice(id: "gpt-6-luna", label: "GPT-6 Luna — yeni nesil (telefon için yavaş kalabilir)"),
        ModelChoice(id: "gpt-6-sol", label: "GPT-6 Sol — daha güçlü, daha yavaş"),
        ModelChoice(id: "gpt-6.1-sol", label: "GPT-6.1 Sol — en güçlü, en yavaş"),
        ModelChoice(id: "gpt-4o-mini", label: "GPT-4o mini — hızlı, eski nesil"),
    ],
    "ollama": [
        ModelChoice(id: "qwen2.5:7b", label: "Qwen 2.5 7B — yerel, hızlı, Türkçesi iyi (≈5 GB)"),
        ModelChoice(id: "gemma4:12b", label: "Gemma 4 12B — yerel, yeni nesil (≈8 GB), 24 GB için önerilen"),
        ModelChoice(id: "gemma4:26b", label: "Gemma 4 26B (A4B) — yerel, güçlü (≈17 GB; 24 GB'ta sıkışık)"),
        ModelChoice(id: "gemma3:12b", label: "Gemma 3 12B — yerel, iyi Türkçe, biraz yavaş (≈8 GB)"),
        ModelChoice(id: "gemma3:4b", label: "Gemma 3 4B — yerel, çok hızlı, daha basit (≈3 GB)"),
        ModelChoice(id: "llama3.1:8b", label: "Llama 3.1 8B — yerel, Türkçesi zayıf (≈5 GB)"),
    ],
] }

/// Yerel Ollama sunucusundaki modeller (çalışmıyorsa nil)
func ollamaModels() -> [String]? {
    guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return nil }
    var req = URLRequest(url: url); req.timeoutInterval = 1.5
    var result: [String]? = nil
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let arr = j["models"] as? [[String: Any]] {
            result = arr.compactMap { $0["name"] as? String }
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 2.5)
    return result
}
func ollamaBinary() -> String? {
    ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

final class AssistantPrefsController: NSObject {
    let app: AppDelegate
    var window: NSWindow!
    var providerPopup: NSPopUpButton!
    var modelPopup: NSPopUpButton!
    var customModel: NSTextField!
    var anthropicKey: NSSecureTextField!
    var openaiKey: NSSecureTextField!
    var anthropicState: NSTextField!
    var openaiState: NSTextField!
    var ownerField: NSTextField!
    var greetingField: NSTextField!
    var hitapField: NSTextField!
    var pullButton: NSButton!
    var pulling = false
    var info: NSTextField!
    var modePopup: NSPopUpButton!
    var rtPopup: NSPopUpButton!
    var delegCheck: NSButton!
    var testButton: NSButton!
    var testing = false

    init(app: AppDelegate) { self.app = app; super.init() }

    func label(_ t: String, bold: Bool = false, size: CGFloat = 12) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        return l
    }

    func build() {
        let W: CGFloat = 560
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 714),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Asistan ayarları"
        window.isReleasedWhenClosed = false
        let v = window.contentView!
        var y: CGFloat = 674

        func row(_ title: String, _ control: NSView, h: CGFloat = 26) {
            let l = label(title); l.frame = NSRect(x: 20, y: y + 4, width: 150, height: 18); v.addSubview(l)
            control.frame = NSRect(x: 175, y: y, width: W - 195, height: h); v.addSubview(control)
            y -= h + 12
        }

        let h0 = label("Konuşma modu", bold: true, size: 13); h0.frame = NSRect(x: 20, y: y, width: 300, height: 18); v.addSubview(h0); y -= 30
        modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (t, id) in [("Klasik — yerel Whisper + dil modeli + yerel ses", "classic"),
                        ("OpenAI Realtime — uçtan uca ses", "realtime"),
                        ("GPT-Live — çift yönlü, dakikada sabit ücret", "live")] {
            modePopup.addItem(withTitle: t); modePopup.lastItem?.representedObject = id
        }
        modePopup.target = self; modePopup.action = #selector(providerInfoRefresh)
        row("Mod:", modePopup)
        rtPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        row("Realtime modeli:", rtPopup)
        delegCheck = NSButton(checkboxWithTitle: "Bilgi sorularını dil modeliyle cevapla", target: nil, action: nil)
        row("GPT-Live arka ucu:", delegCheck)

        let h1 = label("Dil modeli (klasik mod, notlar/özet, GPT-Live arka ucu)", bold: true, size: 13); h1.frame = NSRect(x: 20, y: y, width: 520, height: 18); v.addSubview(h1); y -= 30
        providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        providerPopup.addItem(withTitle: "Anthropic (Claude)"); providerPopup.lastItem?.representedObject = "anthropic"
        providerPopup.addItem(withTitle: "OpenAI"); providerPopup.lastItem?.representedObject = "openai"
        providerPopup.addItem(withTitle: "Yerel (Ollama) — internetsiz"); providerPopup.lastItem?.representedObject = "ollama"
        providerPopup.target = self; providerPopup.action = #selector(providerChanged)
        row("Sağlayıcı:", providerPopup)
        modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modelPopup.target = self; modelPopup.action = #selector(providerInfoRefresh)
        row("Model:", modelPopup)
        customModel = NSTextField(); customModel.placeholderString = "İsteğe bağlı: listede olmayan model kimliği (ör. gpt-4.1-nano)"
        row("Özel model:", customModel)

        y -= 6
        let h2 = label("API anahtarları (yalnızca .env dosyasına yazılır, loga düşmez)", bold: true, size: 13)
        h2.frame = NSRect(x: 20, y: y, width: 500, height: 18); v.addSubview(h2); y -= 30
        anthropicKey = NSSecureTextField(); anthropicKey.placeholderString = "sk-ant-… (boş bırakılırsa mevcut anahtar korunur)"
        row("Anthropic:", anthropicKey)
        anthropicState = label("", size: 11); anthropicState.textColor = .secondaryLabelColor
        anthropicState.frame = NSRect(x: 175, y: y + 22, width: 360, height: 14); v.addSubview(anthropicState)
        openaiKey = NSSecureTextField(); openaiKey.placeholderString = "sk-… (boş bırakılırsa mevcut anahtar korunur)"
        row("OpenAI:", openaiKey)
        openaiState = label("", size: 11); openaiState.textColor = .secondaryLabelColor
        openaiState.frame = NSRect(x: 175, y: y + 22, width: 360, height: 14); v.addSubview(openaiState)

        y -= 6
        let h3 = label("Kimlik ve karşılama", bold: true, size: 13); h3.frame = NSRect(x: 20, y: y, width: 300, height: 18); v.addSubview(h3); y -= 30
        ownerField = NSTextField(); ownerField.placeholderString = "Mehmet  (asistan \"… Bey\" der)"
        row("Adın:", ownerField)
        greetingField = NSTextField(); greetingField.placeholderString = "Boş: varsayılan karşılama. Değiştirirsen ses TTS ile üretilir."
                        row("Karşılama metni:", greetingField, h: 60)
        hitapField = NSTextField(); hitapField.placeholderString = "Rehber adı=Hitap; ör.  Aşkım=Tuba Hanım; Anne=Ayşe Hanım"
        row("Özel hitaplar:", hitapField)

        info = label("", size: 11); info.textColor = .secondaryLabelColor
        info.frame = NSRect(x: 20, y: 52, width: W - 40, height: 46); v.addSubview(info)

        let saveBtn = NSButton(title: "Kaydet ve asistanı yeniden başlat", target: self, action: #selector(saveTapped))
        saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 20, y: 14, width: 260, height: 30); v.addSubview(saveBtn)
        testButton = NSButton(title: "Bağlantıyı sına", target: self, action: #selector(testTapped))
        testButton.bezelStyle = .rounded
        testButton.frame = NSRect(x: 390, y: 14, width: 150, height: 30)
        v.addSubview(testButton)
        pullButton = NSButton(title: "Modeli indir", target: self, action: #selector(pullModel))
        pullButton.bezelStyle = .rounded
        pullButton.frame = NSRect(x: 390, y: 14, width: 150, height: 30)
        pullButton.isHidden = true
        v.addSubview(pullButton)
        let cancel = NSButton(title: "Kapat", target: self, action: #selector(closeTapped))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 290, y: 14, width: 90, height: 30); v.addSubview(cancel)
    }

    func fillRealtime(selected: String) {
        rtPopup.removeAllItems()
        let presets: [(String, String)] = [
            ("gpt-realtime-1.5", "gpt-realtime-1.5 — önerilen"),
            ("gpt-realtime", "gpt-realtime — ilk nesil, kararlı"),
            ("gpt-realtime-2.1-mini", "gpt-realtime-2.1-mini — ucuz, ortam sesine hassas"),
        ]
        var found = false
        for (id, label) in presets {
            rtPopup.addItem(withTitle: label); rtPopup.lastItem?.representedObject = id
            if id == selected { rtPopup.select(rtPopup.lastItem); found = true }
        }
        if !found && !selected.isEmpty {
            rtPopup.addItem(withTitle: selected); rtPopup.lastItem?.representedObject = selected
            rtPopup.select(rtPopup.lastItem)
        }
    }

    /// Kaydedilmiş ayarlarla kısa gerçek istekler yapar (görüşme içeriği gönderilmez; küçük API ücreti olabilir)
    @objc func testTapped() {
        guard !testing else { return }
        testing = true
        testButton.isEnabled = false
        info.stringValue = "Sınanıyor… (kayıtlı ayarlar kullanılır; değişiklik yaptıysan önce kaydet)"
        let py = app.projectDir.appendingPathComponent(".venv/bin/python")
        let script = app.resDir.appendingPathComponent("agent.py")
        let home = app.projectDir
        DispatchQueue.global().async { [weak self] in
            var out = ""
            if FileManager.default.isExecutableFile(atPath: py.path) {
                let p = Process()
                p.executableURL = py
                p.arguments = ["-u", script.path, "--selftest"]
                p.currentDirectoryURL = home
                var env = ProcessInfo.processInfo.environment
                env["PYTHONUNBUFFERED"] = "1"
                env["ASISTAN_HOME"] = home.path
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 45) { if p.isRunning { p.terminate() } }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    out = String(decoding: data, as: UTF8.self)
                } catch {
                    out = "FAIL: Sınama başlatılamadı: \(error.localizedDescription)"
                }
            } else {
                out = "FAIL: Python ortamı bulunamadı (.venv)"
            }
            let lines = out.components(separatedBy: "\n").filter { $0.hasPrefix("OK:") || $0.hasPrefix("FAIL:") || $0.hasPrefix("ATLA:") }
            let text = lines.isEmpty ? "Sınama çıktısı alınamadı: " + String(out.suffix(160))
                : lines.map { $0.replacingOccurrences(of: "OK:", with: "✅").replacingOccurrences(of: "FAIL:", with: "❌").replacingOccurrences(of: "ATLA:", with: "➖") }.joined(separator: "\n")
            DispatchQueue.main.async {
                self?.testing = false
                self?.testButton.isEnabled = true
                self?.info.stringValue = text
            }
        }
    }

    func fillModels(provider: String, selected: String) {
        modelPopup.removeAllItems()
        var found = false
        for m in ModelCatalog.all[provider] ?? [] {
            modelPopup.addItem(withTitle: m.label)
            modelPopup.lastItem?.representedObject = m.id
            if m.id == selected { modelPopup.select(modelPopup.lastItem); found = true }
        }
        customModel.stringValue = found || selected.isEmpty ? "" : selected
    }


    @objc func pullModel() {
        guard !pulling else { return }
        let model = (customModel.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
                     ? (modelPopup.selectedItem?.representedObject as? String) : customModel.stringValue.trimmingCharacters(in: .whitespaces)) ?? ""
        guard !model.isEmpty else { return }
        guard let bin = ollamaBinary() else {
            NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
            info.stringValue = "Ollama'yı indirip kur, çalıştır; sonra bu düğmeye tekrar bas."
            return
        }
        pulling = true
        pullButton.isEnabled = false
        info.stringValue = "Ollama başlatılıyor…"
        DispatchQueue.global().async { [weak self] in
            if ollamaModels() == nil {
                let o = Process(); o.executableURL = URL(fileURLWithPath: "/usr/bin/open"); o.arguments = ["-a", "Ollama"]
                try? o.run(); o.waitUntilExit()
                for _ in 0..<12 where ollamaModels() == nil { Thread.sleep(forTimeInterval: 1) }
                if ollamaModels() == nil {
                    let sv = Process(); sv.executableURL = URL(fileURLWithPath: bin); sv.arguments = ["serve"]
                    try? sv.run()
                    for _ in 0..<8 where ollamaModels() == nil { Thread.sleep(forTimeInterval: 1) }
                }
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["pull", model]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let t = String(data: d, encoding: .utf8) else { return }
                let clean = t.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                if let last = clean.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).last {
                    DispatchQueue.main.async { self?.info.stringValue = "İndiriliyor: \(last)" }
                }
            }
            do { try p.run(); p.waitUntilExit() } catch {
                DispatchQueue.main.async { self?.info.stringValue = "İndirme başlatılamadı: \(error.localizedDescription)" }
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.pulling = false
                self?.pullButton.isEnabled = true
                self?.updateInfo()
            }
        }
    }

    @objc func providerInfoRefresh() { updateInfo() }

    @objc func providerChanged() {
        let provider = (providerPopup.selectedItem?.representedObject as? String) ?? "anthropic"
        fillModels(provider: provider, selected: "")
        updateInfo()
    }

    func updateInfo() {
        let env = app.readEnv()
        let a = (env["ANTHROPIC_API_KEY"] ?? "").count > 20, o = (env["OPENAI_API_KEY"] ?? "").count > 20
        anthropicState.stringValue = a ? "✅ kayıtlı" : "⬜️ girilmedi"
        openaiState.stringValue = o ? "✅ kayıtlı" : "⬜️ girilmedi"
        let provider = (providerPopup.selectedItem?.representedObject as? String) ?? "anthropic"
        pullButton.isHidden = provider != "ollama"
        testButton.isHidden = provider == "ollama"
        let convMode = (modePopup.selectedItem?.representedObject as? String) ?? "classic"
        if convMode != "classic" && !o {
            info.stringValue = "⚠️ \(convMode == "live" ? "GPT-Live" : "Realtime") için OpenAI API anahtarı gerekli; aşağıya gir."
            return
        }
        if provider == "ollama" {
            let model = (customModel.stringValue.isEmpty ? (modelPopup.selectedItem?.representedObject as? String) : customModel.stringValue) ?? ""
            if let list = ollamaModels() {
                let have = list.contains { $0 == model || $0.hasPrefix(model + ":") || model.hasPrefix($0) }
                info.stringValue = have
                    ? "✅ Ollama çalışıyor ve \(model) yüklü. API anahtarı gerekmez. Kaydedince asistan yeniden başlar."
                    : "⚠️ Ollama çalışıyor ama \(model) indirilmemiş. \"Modeli indir\" düğmesine bas (birkaç GB, bir kez)."
            } else {
                info.stringValue = ollamaBinary() == nil
                    ? "⚠️ Ollama kurulu değil. \"Modeli indir\" düğmesi ollama.com indirme sayfasını açar; kurup Ollama'yı çalıştır."
                    : "⚠️ Ollama çalışmıyor. \"Modeli indir\" düğmesi onu başlatıp modeli indirir."
            }
            return
        }
        let ok = provider == "openai" ? o : a
        info.stringValue = ok
            ? "Seçili sağlayıcının anahtarı var. Kaydedince asistan yeniden başlar (yaklaşık 10 sn)."
            : "⚠️ Seçili sağlayıcı için API anahtarı yok; kaydetmeden önce gir."
    }

    func load() {
        let env = app.readEnv()
        let provider = (env["LLM_PROVIDER"] ?? "anthropic").lowercased()
        providerPopup.selectItem(at: ["anthropic": 0, "openai": 1, "ollama": 2][provider] ?? 0)
        let model = env["LLM_MODEL"] ?? env["CLAUDE_MODEL"] ?? ""
        fillModels(provider: provider, selected: model)
        ownerField.stringValue = env["OWNER_NAME"] ?? ""
        greetingField.stringValue = env["GREETING_TEXT"] ?? ""
        hitapField.stringValue = env["HITAP"] ?? ""
        let convMode = (env["CONVERSATION_MODE"] ?? "classic").lowercased()
        modePopup.selectItem(at: ["classic": 0, "realtime": 1, "live": 2][convMode] ?? 0)
        fillRealtime(selected: env["RT_MODEL"] ?? "gpt-realtime")
        delegCheck.state = (env["LIVE_DELEGATION"] ?? "client").lowercased() == "off" ? .off : .on
        anthropicKey.stringValue = ""; openaiKey.stringValue = ""
        updateInfo()
    }

    @objc func saveTapped() {
        let provider = (providerPopup.selectedItem?.representedObject as? String) ?? "anthropic"
        let custom = customModel.stringValue.trimmingCharacters(in: .whitespaces)
        let model = custom.isEmpty ? ((modelPopup.selectedItem?.representedObject as? String) ?? "") : custom
        var changes: [String: String?] = [
            "LLM_PROVIDER": provider, "LLM_MODEL": model, "CLAUDE_MODEL": nil,
            "OWNER_NAME": ownerField.stringValue.trimmingCharacters(in: .whitespaces),
            "GREETING_TEXT": greetingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            "HITAP": hitapField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            "CONVERSATION_MODE": (modePopup.selectedItem?.representedObject as? String) ?? "classic",
            "RT_MODEL": (rtPopup.selectedItem?.representedObject as? String) ?? "gpt-realtime",
            "LIVE_DELEGATION": delegCheck.state == .on ? "client" : "off",
        ]
        let ak = anthropicKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = openaiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if ak.count > 20 { changes["ANTHROPIC_API_KEY"] = ak }
        if ok.count > 20 { changes["OPENAI_API_KEY"] = ok }
        guard app.updateEnv(changes) else { info.stringValue = "Kaydedilemedi; app.log'a bak."; return }
        anthropicKey.stringValue = ""; openaiKey.stringValue = ""
        updateInfo()
        if app.hasProviderKey() {
            app.restartAgent()
            info.stringValue = "Kaydedildi: \(provider) / \(model). Asistan yeniden başlatılıyor…"
        } else {
            info.stringValue = "Kaydedildi ama seçili sağlayıcının API anahtarı yok; asistan başlatılmadı."
        }
    }

    @objc func closeTapped() { window.orderOut(nil) }

    func show() {
        if window == nil { build() }
        load()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

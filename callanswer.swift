// callanswer.swift
// Minimal test: iPhone'dan Mac'e yönlendirilen gelen aramayı otomatik açar.
// Ses/yapay zeka YOK. Amaç sadece "arama otomatik açılabiliyor mu?" sorusunu test etmek.
//
// Çalıştırma:   swift callanswer.swift
// Seçenekler:   --dry-run  (butonu bulur ama basmaz)
//               --dump     (Bildirim Merkezi'ndeki tüm öğeleri yazdırır, hata ayıklama için)

import Cocoa
import ApplicationServices
import AVFoundation
import CoreAudio

let acceptWords = ["accept", "answer", "kabul", "yanıtla", "yanitla", "cevapla"]
let rejectWords = ["decline", "reject", "reddet", "ignore", "dismiss", "close", "kapat"]

let args = CommandLine.arguments
let dumpMode = args.contains("--dump")
let dryRun = args.contains("--dry-run")

func out(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

// MARK: - Accessibility yardımcıları

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func str(_ el: AXUIElement, _ name: String) -> String {
    (attr(el, name) as? String) ?? ""
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

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

func isAccept(_ text: String) -> Bool {
    let t = text.lowercased()
    return acceptWords.contains { t.contains($0) } && !rejectWords.contains { t.contains($0) }
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

// Yeşil "kabul" düğmesinin bildirim çerçevesine göre göreli konumu (ekran görüntüsünden ölçüldü)
let acceptRelX: CGFloat = 0.864
let acceptRelY: CGFloat = 0.073
// Kompakt bildirim (yeşil/kırmızı düğmeler sağ üstte): ekran görüntüsünden ölçüldü
let compactRelX: CGFloat = 0.861
let compactRelY: CGFloat = 0.316

// MARK: - BlackHole ses seviyesini tam seviyeye çek

func deviceID(forUID uid: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = withUnsafeMutablePointer(to: &cfUID) { p in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
    }
    return (st == noErr && dev != 0) ? dev : nil
}

func forceFullVolume(uid: String) {
    guard let dev = deviceID(forUID: uid) else { return }
    for (scope, scopeName) in [(kAudioDevicePropertyScopeOutput, "çıkış"), (kAudioDevicePropertyScopeInput, "giriş")] {
        for el in UInt32(0)...2 {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: scope, mElement: el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var cur: Float32 = 0
            var sz = UInt32(MemoryLayout<Float32>.size)
            _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &cur)
            if abs(cur - 1.0) > 0.01 {
                var v: Float32 = 1.0
                let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
                out("BlackHole \(scopeName) ses seviyesi (kanal \(el)): \(cur) -> 1.0 (durum \(st))")
            }
        }
    }
}

// MARK: - Ses çalma (sanal mikrofona)

let virtualMicUID = "BlackHole2ch_UID"
let greetingPath = FileManager.default.currentDirectoryPath + "/sesler/karsilama_st.wav"
var activePlayer: AVAudioPlayer?

func playWav(_ path: String, deviceUID: String) {
    forceFullVolume(uid: deviceUID)
    do {
        let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        p.currentDevice = deviceUID
        // Aygıt bulunamazsa ses hoparlöre kaçmasın diye kontrol et
        guard p.currentDevice == deviceUID else {
            out("HATA: '\(deviceUID)' aygıtı bulunamadı. BlackHole 2ch kurulu mu? Ses çalınmadı.")
            return
        }
        p.prepareToPlay()
        activePlayer = p
        out("Ses çalınıyor -> \(deviceUID) (\(String(format: "%.1f", p.duration)) sn)")
        p.play()
    } catch {
        out("Ses dosyası açılamadı: \(error)")
    }
}

func onAnswered() {
    forceFullVolume(uid: "BlackHole16ch_UID"); forceFullVolume(uid: "BlackHole2ch_UID")
    // --agent: Python ajanını tetikle (karşılamayı ajan söyler)
    if args.contains("--agent") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let p = FileManager.default.currentDirectoryPath + "/go.flag"
            FileManager.default.createFile(atPath: p, contents: Data())
            out("Ajan tetiklendi (go.flag oluşturuldu)")
        }
        return
    }
    // Arama bağlandıktan sonra karşı tarafın duyması için kısa bir bekleme
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        playWav(greetingPath, deviceUID: virtualMicUID)
    }
}

// MARK: - Ana döngü


struct Candidate {
    let element: AXUIElement
    let action: String
    let description: String
}

var lastPress = Date.distantPast
var lastDump = ""
// Arama bir kez açıldıktan sonra, bildirim tamamen kaybolana kadar bir daha tıklama
var answeredCall = false
var missingScans = 0

func scan() {
    guard let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.notificationcenterui").first else { return }
    let root = AXUIElementCreateApplication(app.processIdentifier)

    var candidate: Candidate?
    var callGroup: AXUIElement?
    var dumpLines: [String] = []

    walk(root) { el, depth in
        let role = str(el, kAXRoleAttribute as String)
        let lbls = labels(el)
        let acts = actionNames(el)

        if dumpMode {
            let indent = String(repeating: "  ", count: depth)
            dumpLines.append("\(indent)\(role) \(lbls) actions=\(acts)")
        }
        if callGroup == nil,
           lbls.contains(where: { $0.uppercased().contains("FACETIME_NOTIFICATION") || $0.lowercased().contains("facetime notification") }) {
            callGroup = el
        }
        if candidate != nil { return }

        if role == "AXButton", lbls.contains(where: isAccept) {
            candidate = Candidate(element: el, action: kAXPressAction as String,
                                  description: "buton \(lbls)")
            return
        }
        if let act = acts.first(where: isAccept) {
            candidate = Candidate(element: el, action: act,
                                  description: "özel eylem '\(act.replacingOccurrences(of: "\n", with: " "))'")
        }
    }

    if dumpMode && dumpLines.count > 1 {
        let joined = dumpLines.joined(separator: "\n")
        if joined != lastDump {
            lastDump = joined
            out("--- Bildirim Merkezi ağacı (değişti) ---")
            print(joined)
            fflush(stdout)
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let block = "[\(f.string(from: Date()))] --- ağaç ---\n\(joined)\n\n"
            let path = FileManager.default.currentDirectoryPath + "/dump.txt"
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(block.data(using: .utf8)!); h.closeFile()
            } else {
                try? block.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    // Bildirim ~2 sn boyunca görünmezse yeni bir arama bekleniyor demektir
    if callGroup == nil && candidate == nil {
        missingScans += 1
        if missingScans > 5 { answeredCall = false }
    } else {
        missingScans = 0
    }

    if candidate == nil {
        guard !answeredCall else { return }
        // Gelen arama bildirimi büyüktür; görüşme sırasındaki küçük çubuğa tıklama
        guard let g = callGroup, let fr = frameOf(g), fr.width > 250, fr.height > 60 else { return }
        let isCompact = fr.height <= 250
        if isCompact { return }  // kompakt bildirimde "Answer" düğmesi AX ile bulunur; koordinat tıklaması yanlış noktaya düşebiliyor
        guard Date().timeIntervalSince(lastPress) > 6 else { return }
        lastPress = Date()
        let pt = isCompact ? CGPoint(x: fr.minX + fr.width * compactRelX, y: fr.minY + fr.height * compactRelY) : CGPoint(x: fr.minX + fr.width * acceptRelX, y: fr.minY + fr.height * acceptRelY)
        if dryRun {
            out("BULUNDU (dry-run, tıklanmadı): bildirim çerçevesi=\(fr), tıklanacak nokta=\(pt)")
            return
        }
        clickAt(pt)
        answeredCall = true
        out("ARAMA AÇILDI (fare tıklaması): \(pt)")
        onAnswered()
        return
    }
    guard let c = candidate else { return }
    guard !answeredCall else { return }
    guard Date().timeIntervalSince(lastPress) > 6 else { return }
    lastPress = Date()

    if dryRun {
        out("BULUNDU (dry-run, basılmadı): \(c.description)")
        return
    }
    let result = AXUIElementPerformAction(c.element, c.action as CFString)
    out(result == .success
        ? "ARAMA AÇILDI: \(c.description)"
        : "Basma başarısız (\(result.rawValue)): \(c.description)")
    if result == .success { answeredCall = true; onAnswered() }
}

// MARK: - Tanılama: ses sanal mikrofona ulaşıyor mu?

final class PeakBox { var peak: Float = 0 }

func defaultInputName() -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return "?" }
    var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var cfName: CFString = "" as CFString
    var nsize = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &cfName) {
        AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nsize, $0)
    }
    return st == noErr ? (cfName as String) : "?"
}

func checkLoop() {
    out("Varsayılan giriş aygıtı: \(defaultInputName())")
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let fmt = input.outputFormat(forBus: 0)
    let box = PeakBox()
    input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
        guard let ch = buf.floatChannelData?[0] else { return }
        var m: Float = 0
        for i in 0..<Int(buf.frameLength) { m = max(m, abs(ch[i])) }
        if m > box.peak { box.peak = m }
    }
    do { try engine.start() } catch {
        out("Mikrofon başlatılamadı (izin verildi mi?): \(error)")
        return
    }
    var files = [greetingPath]
    if let a = args.first(where: { $0.hasPrefix("--file=") }) {
        files = String(a.dropFirst(7)).split(separator: ",").map { String($0) }
    }
    for f in files {
        box.peak = 0
        playWav(f, deviceUID: virtualMicUID)
        RunLoop.main.run(until: Date().addingTimeInterval((activePlayer?.duration ?? 0) + 0.7))
        out(String(format: "%@ -> giriş zirve seviyesi: %.4f", f, box.peak))
    }
    engine.stop()
    out("Bitti. 0.01'in altı = ses ulaşmıyor; 0.3-0.9 arası = iyi seviye.")
}

// MARK: - Başlat

if args.contains("--check-loop") {
    checkLoop()
    exit(0)
}

if args.contains("--test-sound") {
    playWav(greetingPath, deviceUID: virtualMicUID)
    RunLoop.main.run(until: Date().addingTimeInterval((activePlayer?.duration ?? 0) + 1))
    exit(0)
}


let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(opts) else {
    out("Erişilebilirlik izni yok. Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik bölümünde")
    out("Terminal'e (veya betiği çalıştırdığın uygulamaya) izin ver, sonra betiği yeniden başlat.")
    exit(1)
}

forceFullVolume(uid: "BlackHole16ch_UID"); forceFullVolume(uid: "BlackHole2ch_UID")
out("Dinleniyor… (dry-run: \(dryRun), dump: \(dumpMode)). Çıkmak için Ctrl+C.")
Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in scan() }
RunLoop.main.run()

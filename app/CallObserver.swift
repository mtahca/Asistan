import Cocoa
import ApplicationServices

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
    /// While an answered call is being confirmed, poll faster so the session starts sooner.
    var urgent = false
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
        queue.asyncAfter(deadline: .now() + (urgent ? 0.2 : 0.6)) { self.poll() }
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

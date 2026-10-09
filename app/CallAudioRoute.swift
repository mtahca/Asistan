import Cocoa
import ApplicationServices
import CoreAudio

/// What one call app's menus showed and what was changed.
struct RouteReport {
    var app: String
    var running = false
    var plan: MenuRoutePlan?
    var pressedInput = false
    var pressedOutput = false
    var inputReady: Bool { plan?.inputReady == true || pressedInput }
    var summary: String {
        guard running else { return app + ": çalışmıyor" }
        guard let plan = plan, plan.inputListed else { return app + ": menüde mikrofon listesi bulunamadı" }
        var text = app + ": mikrofon " + (pressedInput ? BetaAudio.microphoneName + " seçildi" : (plan.inputCurrent ?? "seçili değil"))
        text += inputReady ? " ✓" : " ✗"
        if let output = plan.outputCurrent {
            text += " · hoparlör " + (pressedOutput ? (plan.outputPress?.title ?? output) + " seçildi" : output)
        }
        return text
    }
}

/// Makes call apps send Asistan's voice: picks Asistan Mikrofonu in their own menus, verifies with
/// Core Audio which processes record from it and, as a last resort, makes it the system input
/// for the call. Everything here blocks on other apps; call it from a background queue only.
enum CallAudioRoute {
    static let apps: [(bundleID: String, name: String)] = [
        ("com.apple.mobilephone", "Telefon"), ("com.apple.FaceTime", "FaceTime"),
        ("net.whatsapp.WhatsApp", "WhatsApp"), ("desktop.WhatsApp", "WhatsApp"),
    ]
    static let restoreKey = "restoreDefaultInputUID"
    static var assistantDevices: [String] { [BetaAudio.listenName, BetaAudio.microphoneName, BetaAudio.playbackName] }

    // MARK: Menus

    /// Menu children with the AXMenu level skipped, identical for reading and pressing.
    static func menuChildren(_ element: AXUIElement) -> [AXUIElement] {
        children(element).flatMap { str($0, kAXRoleAttribute as String) == "AXMenu" ? children($0) : [$0] }
    }
    static func menuNode(_ element: AXUIElement, depth: Int) -> MenuNode {
        var node = MenuNode(title: str(element, kAXTitleAttribute as String))
        node.enabled = (attr(element, kAXEnabledAttribute as String) as? Bool) ?? true
        node.checked = !str(element, "AXMenuItemMarkChar").isEmpty
        if depth < 4 { node.children = menuChildren(element).map { menuNode($0, depth: depth + 1) } }
        return node
    }
    static func menuElement(at path: [Int], from root: AXUIElement) -> AXUIElement? {
        var current = root
        for index in path {
            let items = menuChildren(current)
            guard index < items.count else { return nil }
            current = items[index]
        }
        return current
    }

    static func check(bundleID: String, name: String, apply: Bool, preferredOutput: String?) -> RouteReport {
        var report = RouteReport(app: name)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return report }
        report.running = true
        func read() -> (bar: AXUIElement, plan: MenuRoutePlan)? {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.5)
            guard let value = attr(root, kAXMenuBarAttribute as String) else { return nil }
            let bar = value as! AXUIElement
            let menus = menuChildren(bar).map { menuNode($0, depth: 1) }
            return (bar, MenuRoute.plan(menus, microphone: BetaAudio.microphoneName, assistantDevices: assistantDevices, preferredOutput: preferredOutput))
        }
        var found = read()
        if found?.plan.inputListed != true, apply {
            // A background app may publish an empty menu bar; bring it forward briefly, as Alpha did for FaceTime.
            let previous = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
            DispatchQueue.main.sync { _ = app.activate(options: []) }
            usleep(700_000)
            found = read()
            if let previous = previous, previous.processIdentifier != app.processIdentifier {
                DispatchQueue.main.sync { _ = previous.activate(options: []) }
            }
        }
        guard let menu = found else { return report }
        report.plan = menu.plan
        guard apply else { return report }
        if let choice = menu.plan.inputPress, let item = menuElement(at: choice.path, from: menu.bar) {
            report.pressedInput = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        if let choice = menu.plan.outputPress, let item = menuElement(at: choice.path, from: menu.bar) {
            report.pressedOutput = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        return report
    }

    /// Menu bar outline for the diagnostics file: titles, ✓ marks and disabled headings.
    static func describeMenus(bundleID: String) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return "" }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let value = attr(root, kAXMenuBarAttribute as String) else { return "Menü çubuğu okunamadı\n" }
        var out = ""
        func add(_ node: MenuNode, _ depth: Int) {
            out += String(repeating: "  ", count: depth) + (node.checked ? "✓ " : "") + (node.title.isEmpty ? "—" : node.title) + (node.enabled ? "" : " (pasif)") + "\n"
            for child in node.children { add(child, depth + 1) }
        }
        for menu in menuChildren(value as! AXUIElement).map({ menuNode($0, depth: 1) }) { add(menu, 0) }
        return out
    }

    // MARK: Verification

    static func processBundleID(_ process: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: fourCC("pbid"), mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0) }
        guard status == noErr, let id = value else { return "?" }
        return id.takeRetainedValue() as String
    }

    /// Processes recording from the device now (macOS 14.2+ process objects). nil: macOS did not say.
    static func processesRecording(from device: AudioDeviceID) -> [String]? {
        var address = AudioObjectPropertyAddress(mSelector: fourCC("prs#"), mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(hwSystem, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(hwSystem, &address, 0, nil, &size, &processes) == noErr else { return nil }
        var users: [String] = [], reported = false
        for process in processes {
            var devicesAddress = AudioObjectPropertyAddress(mSelector: fourCC("pdv#"), mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var devicesSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(process, &devicesAddress, 0, nil, &devicesSize) == noErr else { continue }
            reported = true
            var devices = [AudioObjectID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
            guard !devices.isEmpty, AudioObjectGetPropertyData(process, &devicesAddress, 0, nil, &devicesSize, &devices) == noErr,
                  devices.contains(where: { $0 == device || subDevices(of: $0).contains(device) }) else { continue }
            let id = processBundleID(process)
            if !id.contains("rogueamoeba") { users.append(id) }
        }
        return reported ? users : nil
    }
    /// Call audio often runs through a private aggregate device (echo cancellation) that wraps the microphone.
    static func subDevices(of device: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }
    static func microphoneUsers() -> [String]? {
        namedAudioDevice(BetaAudio.microphoneName, input: true).flatMap { processesRecording(from: $0) }
    }

    // MARK: System input fallback

    static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(hwSystem, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }
    /// Apps on "Use System Setting" follow this. The previous input is stored first so a crash cannot strand it.
    static func useMicrophoneAsDefaultInput() -> Bool {
        guard let microphone = namedAudioDevice(BetaAudio.microphoneName, input: true) else { return false }
        let current = getDefault(kAudioHardwarePropertyDefaultInputDevice)
        if current == microphone { return true }
        if UserDefaults.standard.string(forKey: restoreKey) == nil, let current = current {
            UserDefaults.standard.set(deviceUIDString(current), forKey: restoreKey)
        }
        return setDefaultInput(microphone)
    }
    /// Puts the stored input back, unless the user changed the system input meanwhile.
    @discardableResult static func restoreDefaultInput() -> Bool {
        guard let uid = UserDefaults.standard.string(forKey: restoreKey) else { return false }
        UserDefaults.standard.removeObject(forKey: restoreKey)
        guard let microphone = namedAudioDevice(BetaAudio.microphoneName, input: true),
              getDefault(kAudioHardwarePropertyDefaultInputDevice) == microphone else { return false }
        guard let previous = deviceID(forUID: uid) ?? builtinDevice(input: true) else { return false }
        return setDefaultInput(previous)
    }
}

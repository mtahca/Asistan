import Cocoa
import CoreAudio

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

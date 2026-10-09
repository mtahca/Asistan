import Cocoa

final class MobileSettingsController: NSObject, NSWindowDelegate {
    let app: AppDelegate
    var window: NSWindow!
    var mobileToggle: NSButton!
    var focusToggle: NSButton!
    var mobileStatus: NSTextField!
    var focusStatus: NSTextField!
    var codeLabel: NSTextField!
    var rotateButton: NSButton!
    var timer: Timer?
    var addresses: [String] = []
    init(app: AppDelegate) { self.app = app; super.init(); build() }
    func label(_ text: String, _ y: CGFloat, height: CGFloat = 48, bold: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.frame = NSRect(x: 24, y: y, width: 552, height: height)
        f.font = bold ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 13)
        f.isSelectable = true; window.contentView!.addSubview(f); return f
    }
    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 590), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Asistan — iPhone ve Odak"; window.isReleasedWhenClosed = false; window.delegate = self
        mobileToggle = NSButton(checkboxWithTitle: "Asistan Mobile bağlantısını aç", target: self, action: #selector(toggleMobile))
        mobileToggle.frame = NSRect(x: 24, y: 543, width: 550, height: 28); window.contentView!.addSubview(mobileToggle)
        mobileStatus = label("", 509, height: 30)
        codeLabel = label("", 465, height: 40, bold: true)
        _ = label("Aynı Wi-Fi'deki telefonda Asistan Mobile → Ayarlar → Mac listesinden adı ‘— Asistan’ ile biten bilgisayarı seçin ya da Mac adresi alanına bu Mac’in yerel IP adresini yazın. Yukarıdaki kodu telefondaki eşleştirme alanına girin.", 378, height: 82)
        _ = label("Asistan Mobile’ın varsayılan 47821 portu kullanılır; Bonjour listesi de elle adres de çalışır. Eski Beta’yı seçtiyseniz listeden yeniden seçin; kod aynıdır. Bağlantı kodla şifrelenir; kodu bilen cihaz cevaplama, not ve sonlandırma komutlarını kullanabilir.", 291, height: 80)
        rotateButton = NSButton(title: "Eşleştirme kodunu yenile", target: self, action: #selector(rotateCode)); rotateButton.bezelStyle = .rounded
        rotateButton.frame = NSRect(x: 24, y: 249, width: 245, height: 32); window.contentView!.addSubview(rotateButton)
        focusToggle = NSButton(checkboxWithTitle: "Odak açıkken gelen aramaları otomatik cevapla", target: self, action: #selector(toggleFocus))
        focusToggle.frame = NSRect(x: 24, y: 200, width: 552, height: 28); window.contentView!.addSubview(focusToggle)
        focusStatus = label("", 145, height: 48)
        _ = label("Bu seçenek tüm Odak modları için geçerlidir. Odak kapandığında normal cevaplama seçiminiz geri geçer. Duraklatma her iki otomatik modu da durdurur. Durum okunamazsa yalnızca Odak seçeneği otomatik cevap başlatmaz.", 64, height: 72)
        let permission = NSButton(title: "Odak için Tam Disk Erişimi ayarları", target: self, action: #selector(openFocusPermission)); permission.bezelStyle = .rounded
        permission.frame = NSRect(x: 24, y: 20, width: 360, height: 32); window.contentView!.addSubview(permission)
    }
    func show() {
        addresses = LiveProtocol.localAddresses()
        refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        app.focusMonitor.refresh(enabled: app.focusAuto)
        mobileToggle.state = app.mobile.enabled ? .on : .off
        mobileStatus.stringValue = app.mobile.status
        codeLabel.stringValue = app.mobile.enabled ? "Eşleştirme kodu: \(app.mobile.displayCode)" + (addresses.isEmpty ? "" : "\nMac adresi: " + addresses.joined(separator: ", ")) : "Mobil bağlantı kapalı; açınca eşleştirme kodu gösterilir."
        rotateButton.isEnabled = app.mobile.enabled
        focusToggle.state = app.focusAuto ? .on : .off
        focusStatus.stringValue = app.focusAuto ? app.focusMonitor.status : "Odak sırasında otomatik cevaplama kapalı."
        if app.focusAuto && app.focusMonitor.active == nil { focusStatus.stringValue += "\nAsistan’a Tam Disk Erişimi verip yeniden açın." }
    }
    @objc func toggleMobile() { app.mobile.setEnabled(mobileToggle.state == .on); refresh() }
    @objc func toggleFocus() { app.setFocusAuto(focusToggle.state == .on); refresh() }
    @objc func rotateCode() {
        let a = NSAlert(); a.messageText = "Eşleştirme kodu yenilensin mi?"
        a.informativeText = "Bağlı telefonlar ayrılır. Yeni kodu Asistan Mobile'a yeniden girmelisiniz. Mac'teki görüşme devam eder."
        a.addButton(withTitle: "Yenile"); a.addButton(withTitle: "Vazgeç")
        if a.runModal() == .alertFirstButtonReturn { app.mobile.regenerateCode(); refresh() }
    }
    @objc func openFocusPermission() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}

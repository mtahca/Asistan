import Cocoa
import CoreImage

final class MobileSettingsController: NSObject, NSWindowDelegate, SettingsPane {
    let app: AppDelegate
    var window: NSWindow!
    var mobileToggle: NSButton!
    var focusToggle: NSButton!
    var mobileStatus: NSTextField!
    var focusStatus: NSTextField!
    var codeLabel: NSTextField!
    var rotateButton: NSButton!
    var legacyToggle: NSButton!
    var qrView: NSImageView!
    var shownLink = ""
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Asistan — iPhone ve Odak"; window.isReleasedWhenClosed = false; window.delegate = self
        mobileToggle = NSButton(checkboxWithTitle: "Asistan Mobile bağlantısını aç", target: self, action: #selector(toggleMobile))
        mobileToggle.frame = NSRect(x: 24, y: 653, width: 550, height: 28); window.contentView!.addSubview(mobileToggle)
        mobileStatus = label("", 619, height: 30)
        qrView = NSImageView(frame: NSRect(x: 24, y: 405, width: 200, height: 200))
        qrView.imageScaling = .scaleProportionallyUpOrDown; window.contentView!.addSubview(qrView)
        let pairHint = NSTextField(wrappingLabelWithString: "iPhone'da Asistan Mobile → QR kodu tara ile bu kodu okutun ya da iPhone Kamera ile okutup bağlantıyı açın. Kod bu Mac'in adını, adresini ve rastgele bir eşleştirme anahtarını taşır; başkasıyla paylaşmayın.")
        pairHint.frame = NSRect(x: 240, y: 470, width: 336, height: 130); pairHint.isSelectable = true; window.contentView!.addSubview(pairHint)
        rotateButton = NSButton(title: "Eşleştirmeyi yenile", target: self, action: #selector(rotateCode)); rotateButton.bezelStyle = .rounded
        rotateButton.frame = NSRect(x: 240, y: 415, width: 245, height: 32); window.contentView!.addSubview(rotateButton)
        legacyToggle = NSButton(checkboxWithTitle: "Eski 8 haneli kodla bağlanmaya izin ver (eski Asistan Mobile sürümleri için)", target: self, action: #selector(toggleLegacy))
        legacyToggle.frame = NSRect(x: 24, y: 362, width: 552, height: 28); window.contentView!.addSubview(legacyToggle)
        codeLabel = label("", 316, height: 40, bold: true)
        _ = label("QR ile eşleşen telefonlar 47822 portunu, eski kodu kullananlar 47821 portunu kullanır. 8 haneli kod, ağdaki biri tarafından kaydedilen bir bağlantıdan tahmin edilebilir; bütün telefonlarınız QR ile eşleşince eski kodu kapatın. Eşleşen cihaz cevaplama, not ve sonlandırma komutlarını kullanabilir.", 236, height: 76)
        focusToggle = NSButton(checkboxWithTitle: "Odak açıkken gelen aramaları otomatik cevapla", target: self, action: #selector(toggleFocus))
        focusToggle.frame = NSRect(x: 24, y: 200, width: 552, height: 28); window.contentView!.addSubview(focusToggle)
        focusStatus = label("", 145, height: 48)
        _ = label("Bu seçenek tüm Odak modları için geçerlidir. Odak kapandığında normal cevaplama seçiminiz geri geçer. Duraklatma her iki otomatik modu da durdurur. Durum okunamazsa yalnızca Odak seçeneği otomatik cevap başlatmaz.", 64, height: 72)
        let permission = NSButton(title: "Odak için Tam Disk Erişimi ayarları", target: self, action: #selector(openFocusPermission)); permission.bezelStyle = .rounded
        permission.frame = NSRect(x: 24, y: 20, width: 360, height: 32); window.contentView!.addSubview(permission)
    }
    static func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size); image.addRepresentation(rep); return image
    }
    func prepare() {
        addresses = LiveProtocol.localAddresses()
        refresh()
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        app.focusMonitor.refresh(enabled: app.focusAuto)
        mobileToggle.state = app.mobile.enabled ? .on : .off
        mobileStatus.stringValue = app.mobile.status
        let enabled = app.mobile.enabled
        codeLabel.stringValue = !enabled ? "Mobil bağlantı kapalı; açınca eşleştirme QR kodu gösterilir."
            : (app.mobile.legacyEnabled ? "Eski kod: \(app.mobile.displayCode)" : "Eski kodla bağlantı kapalı") + (addresses.isEmpty ? "" : "\nMac adresi: " + addresses.joined(separator: ", "))
        let link = enabled ? PairingLink(key: app.mobile.key, mac: app.mobile.macName, hosts: addresses).url : ""
        if link != shownLink { shownLink = link; qrView.image = link.isEmpty ? nil : Self.qrImage(link) }
        legacyToggle.state = app.mobile.legacyEnabled ? .on : .off; legacyToggle.isEnabled = enabled
        rotateButton.isEnabled = enabled
        focusToggle.state = app.focusAuto ? .on : .off
        focusStatus.stringValue = app.focusAuto ? app.focusMonitor.status : "Odak sırasında otomatik cevaplama kapalı."
        if app.focusAuto && app.focusMonitor.active == nil { focusStatus.stringValue += "\nAsistan’a Tam Disk Erişimi verip yeniden açın." }
    }
    @objc func toggleMobile() { app.mobile.setEnabled(mobileToggle.state == .on); refresh() }
    @objc func toggleLegacy() { app.mobile.setLegacyEnabled(legacyToggle.state == .on); refresh() }
    @objc func toggleFocus() { app.setFocusAuto(focusToggle.state == .on); refresh() }
    @objc func rotateCode() {
        let a = NSAlert(); a.messageText = "Eşleştirme yenilensin mi?"
        a.informativeText = "QR anahtarı ve eski kod yenilenir. Bağlı telefonlar ayrılır; her telefonda yeni QR kodu okutmanız gerekir. Mac'teki görüşme devam eder."
        a.addButton(withTitle: "Yenile"); a.addButton(withTitle: "Vazgeç")
        if a.runModal() == .alertFirstButtonReturn { app.mobile.regenerateCode(); refresh() }
    }
    @objc func openFocusPermission() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    func paneClosed() { timer?.invalidate(); timer = nil }
    func windowWillClose(_ notification: Notification) { paneClosed() }
}

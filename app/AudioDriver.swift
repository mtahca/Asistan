import Cocoa

/// Asistan'ın sanal ses sürücüsü (Asistan-Audio-Driver): "Asistan Sanal Çıkış"a çalınan ses
/// "Asistan Sanal Mikrofon"dan gelir. Uygulama paketinin içinde gelir ve yönetici izniyle kurulur.
enum AudioDriver {
    static let bundleName = "AsistanSes.driver"
    static let installPath = "/Library/Audio/Plug-Ins/HAL/" + bundleName

    static var bundled: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    static var installed: Bool {
        namedAudioDevice(BetaAudio.microphoneName, input: true) != nil && namedAudioDevice(BetaAudio.playbackName, input: false) != nil
    }

    /// Sürücüyü kurar ve Core Audio'yu yeniden başlatır; açık seslerin bir an kesilmesine yol açar.
    /// Hata metni döndürür, başarıda nil.
    static func install() -> String? {
        guard let source = bundled else { return "Uygulama paketinde ses sürücüsü yok; Asistan’ı yeniden derleyin." }
        func quoted(_ s: String) -> String { "quoted form of \"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script = "do shell script \"rm -rf \" & \(quoted(installPath)) & \" && cp -R \" & \(quoted(source.path)) & \" \" & \(quoted(installPath)) & \" && chown -R root:wheel \" & \(quoted(installPath)) & \" && killall coreaudiod\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard let error = error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Kurulum iptal edildi." }
        return "Sürücü kurulamadı: \(error[NSAppleScript.errorMessage] as? String ?? "bilinmeyen hata")"
    }
}

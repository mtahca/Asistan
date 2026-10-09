import Cocoa

final class ModelSettingsController: NSObject {
    let app: AppDelegate
    var window: NSWindow!
    var mode: NSPopUpButton!
    var liveVoice: NSPopUpButton!
    var speechChoiceLabel: NSTextField!
    var speechInfo: NSTextField!
    var privacyInfo: NSTextField!
    var owner: NSTextField!
    var conversation: NSPopUpButton!
    var summary: NSPopUpButton!
    var transcription: NSPopUpButton!
    var speed: NSSlider!
    var speedLabel: NSTextField!
    var feedback: NSTextField!
    var keyStatus: NSTextField!
    var anthropicKey: NSSecureTextField!
    var openAIKey: NSSecureTextField!

    init(app: AppDelegate) { self.app = app; super.init(); build() }
    func label(_ text: String, y: CGFloat, bold: Bool = false, height: CGFloat = 44) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.frame = NSRect(x: 24, y: y, width: 552, height: height)
        view.font = bold ? .boldSystemFont(ofSize: 16) : .systemFont(ofSize: 12)
        window.contentView!.addSubview(view); return view
    }
    func popup(y: CGFloat, items: [(String, String)]) -> NSPopUpButton {
        let view = NSPopUpButton(frame: NSRect(x: 220, y: y, width: 356, height: 28), pullsDown: false)
        for (title, id) in items { view.addItem(withTitle: title); view.lastItem?.representedObject = id }
        window.contentView!.addSubview(view); return view
    }
    @discardableResult func fieldLabel(_ text: String, y: CGFloat) -> NSTextField {
        let view = NSTextField(labelWithString: text); view.frame = NSRect(x: 24, y: y + 4, width: 190, height: 20)
        window.contentView!.addSubview(view); return view
    }
    func secret(y: CGFloat, placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 220, y: y, width: 356, height: 26))
        field.placeholderString = placeholder; window.contentView!.addSubview(field); return field
    }
    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 715), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Asistan Beta — Modeller ve API anahtarları"; window.isReleasedWhenClosed = false
        _ = label("Görüşme ve özet için model seçin", y: 664, bold: true, height: 26)
        fieldLabel("Ses modu", y: 618)
        mode = popup(y: 618, items: [("Yerel ses — mevcut sistem", "local"), ("Çevrimiçi ses — GPT-Live 1", "gpt-live")])
        mode.target = self; mode.action = #selector(updateMode)
        fieldLabel("Adına konuştuğu kişi", y: 568)
        owner = NSTextField(frame: NSRect(x: 220, y: 568, width: 356, height: 26)); window.contentView!.addSubview(owner)
        let models = BetaModelChoice.options.map { ($0.title, $0.choice.selection) }
        fieldLabel("Görüşme / arka plan", y: 522); conversation = popup(y: 522, items: models)
        fieldLabel("Özet modeli", y: 480); summary = popup(y: 480, items: [("Görüşme modeliyle aynı", "")] + models)
        _ = label("OpenAI için önce Luna’yı deneyin. Sol 6.1 düşünme kullandığı için daha geç yanıt verebilir. Her modelin hesap erişimi ve API ücreti farklıdır.", y: 426)
        speechChoiceLabel = fieldLabel("Konuşmayı yazıya çevirme", y: 392)
        transcription = popup(y: 392, items: [("Whisper Large v3 Turbo — hızlı", "mlx-community/whisper-large-v3-turbo"), ("Whisper Large v3 — daha büyük", "mlx-community/whisper-large-v3-mlx")])
        liveVoice = popup(y: 392, items: BetaModelConfiguration.liveVoices.map { ($0 == "marin" ? "Marin — varsayılan" : $0.capitalized, $0) })
        liveVoice.isHidden = true; liveVoice.target = self; liveVoice.action = #selector(updateMode)
        speechInfo = label("Yerel mod: Whisper ve EMA Lightning bu Mac’te çalışır.", y: 348, height: 34)
        fieldLabel("Konuşma hızı", y: 311)
        speed = NSSlider(value: 1, minValue: 0.85, maxValue: 1.2, target: self, action: #selector(updateSpeed))
        speed.frame = NSRect(x: 220, y: 311, width: 274, height: 24); window.contentView!.addSubview(speed)
        speedLabel = NSTextField(labelWithString: "1,00×"); speedLabel.frame = NSRect(x: 508, y: 311, width: 68, height: 20); window.contentView!.addSubview(speedLabel)
        _ = label("API anahtarları", y: 263, bold: true, height: 26)
        fieldLabel("Anthropic anahtarı", y: 231); anthropicKey = secret(y: 231, placeholder: "Yeni anahtar; boşsa mevcut korunur")
        fieldLabel("OpenAI anahtarı", y: 193); openAIKey = secret(y: 193, placeholder: "sk-…; boşsa mevcut korunur")
        keyStatus = label("", y: 152, height: 30)
        privacyInfo = label("Anahtarları yalnızca buraya girin; sohbetten paylaşmanız gerekmez. Kaydetme görüşme yokken uygulanır. Metin ve talimatlar seçtiğiniz sağlayıcıya gönderilir; ham ses bu Mac’te işlenir.", y: 97, height: 50)
        feedback = label("", y: 47, height: 44)
        let save = NSButton(title: "Kaydet ve uygula", target: self, action: #selector(save)); save.bezelStyle = .rounded
        save.frame = NSRect(x: 396, y: 10, width: 180, height: 32); window.contentView!.addSubview(save)
    }
    func choose(_ popup: NSPopUpButton, id: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == id }) { popup.select(item) }
        else { popup.addItem(withTitle: id); popup.lastItem?.representedObject = id; popup.select(popup.lastItem) }
    }
    @objc func updateMode() {
        let online = (mode.selectedItem?.representedObject as? String) == "gpt-live"
        transcription.isEnabled = !online; transcription.isHidden = online
        liveVoice.isEnabled = online; liveVoice.isHidden = !online
        speechChoiceLabel.stringValue = online ? "GPT-Live sesi" : "Konuşmayı yazıya çevirme"
        speed.isEnabled = !online
        speechInfo.stringValue = online ? "GPT-Live 1 dinler ve konuşur; Whisper/EMA kullanılmaz. Ses seçimi yeni görüşmede uygulanır. Görüşme modeli, gerektiğinde arka planda yanıt verir." : "Yerel mod: Whisper ve EMA Lightning bu Mac’te çalışır. Model değişikliği indirme gerektirebilir."
        privacyInfo.stringValue = online ? "GPT-Live modunda görüşme sesi OpenAI’ye gider. Ses oturumu $0,05/dk; arka plan ve özet ayrıca ücretlenir. Anahtarı buraya girin. Değişiklik görüşme yokken uygulanır." : "Anahtarları buraya girin. Metin ve talimatlar seçilen sağlayıcıya gider; ham ses bu Mac’te işlenir. Boş anahtar alanı mevcut anahtarı korur."
    }
    @objc func updateSpeed() { speedLabel.stringValue = String(format: "%.2f×", speed.doubleValue) }
    func refreshKeys(_ values: [String: String]) {
        let anthropic = (values["ANTHROPIC_API_KEY"]?.count ?? 0) > 20
        let openai = (values["OPENAI_API_KEY"]?.count ?? 0) > 20
        keyStatus.stringValue = "Kayıtlı anahtar: Anthropic " + (anthropic ? "✓" : "yok") + " · OpenAI " + (openai ? "✓" : "yok") + " — bağlantıyı kurulum ekranından sınayın."
    }
    func show() {
        let values = app.savedSettings()
        owner.stringValue = values["OWNER_NAME"] ?? "Mehmet"
        choose(mode, id: (try? BetaModelConfiguration.voiceMode(in: values)) ?? "local")
        choose(liveVoice, id: (try? BetaModelConfiguration.liveVoice(in: values)) ?? "marin")
        updateMode()
        do {
            let choices = try BetaModelConfiguration.choices(in: values)
            choose(conversation, id: choices.conversation.selection)
            choose(summary, id: (values["SUMMARY_MODEL"] ?? "").isEmpty && (values["SUMMARY_PROVIDER"] ?? "").isEmpty ? "" : choices.summary.selection)
            feedback.stringValue = ""
        } catch { feedback.stringValue = error.localizedDescription }
        choose(transcription, id: values["WHISPER_MODEL"] ?? "mlx-community/whisper-large-v3-turbo")
        speed.doubleValue = min(1.2, max(0.85, Double(values["TTS_SPEED"] ?? "1") ?? 1)); updateSpeed()
        anthropicKey.stringValue = ""; openAIKey.stringValue = ""; refreshKeys(values)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func save() {
        guard !app.busy, app.setupController?.installing != true, app.setupController?.checkingAPI != true else { feedback.stringValue = "Görüşme, kurulum veya bağlantı testi sürüyor. Bittikten sonra kaydedin."; return }
        let name = owner.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { feedback.stringValue = "Lütfen geçerli bir kişi adı yazın."; return }
        let env = app.projectDir.appendingPathComponent(".env")
        do {
            let previous = FileManager.default.fileExists(atPath: env.path) ? try String(contentsOf: env, encoding: .utf8) : ""
            let selected = try BetaModelChoice.parse(conversation.selectedItem!.representedObject as! String)
            let summaryID = summary.selectedItem!.representedObject as! String
            let selectedSummary = summaryID.isEmpty ? nil : try BetaModelChoice.parse(summaryID)
            var changes = ["VOICE_MODE": mode.selectedItem!.representedObject as! String, "GPT_LIVE_VOICE": liveVoice.selectedItem!.representedObject as! String, "OWNER_NAME": name, "LLM_PROVIDER": selected.provider,
                           "SUMMARY_PROVIDER": selectedSummary?.provider ?? "", "SUMMARY_MODEL": selectedSummary?.model ?? "",
                           "WHISPER_MODEL": transcription.selectedItem!.representedObject as! String,
                           "STT_BACKEND": "mlx", "TTS_SPEED": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), speed.doubleValue)]
            changes[selected.provider == "openai" ? "OPENAI_MODEL" : "CLAUDE_MODEL"] = selected.model
            var updated = try BetaModelConfiguration.updating(previous, with: changes)
            let credentials = ["ANTHROPIC_API_KEY": anthropicKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                               "OPENAI_API_KEY": openAIKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.value.isEmpty }
            if !credentials.isEmpty { updated = try BetaModelConfiguration.updatingCredentials(updated, with: credentials) }
            let missing = try BetaModelConfiguration.missingCredentials(in: BetaModelConfiguration.values(in: updated))
            guard missing.isEmpty else { feedback.stringValue = "Seçtiğiniz modeller için " + missing.map { $0 == "openai" ? "OpenAI" : "Anthropic" }.joined(separator: " ve ") + " anahtarı girin. Mevcut ayarlar korunuyor."; return }
            try updated.write(to: env, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.path)
            anthropicKey.stringValue = ""; openAIKey.stringValue = ""; refreshKeys(BetaModelConfiguration.values(in: updated))
            app.setupController?.invalidateAPICheck()
            if app.setupStatus().py { app.restartAgent() }
            feedback.stringValue = "Kaydedildi. Seçtiğiniz modellerin bağlantısını kurulum ekranından sınayabilirsiniz."
        } catch { feedback.stringValue = "Ayarlar kaydedilemedi: " + error.localizedDescription }
    }
}

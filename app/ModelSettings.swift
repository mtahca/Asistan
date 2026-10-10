import Cocoa

final class ModelSettingsController: NSObject, SettingsPane {
    let app: AppDelegate
    var window: NSWindow!
    var mode: NSPopUpButton!
    var liveVoice: NSPopUpButton!
    var geminiVoice: NSPopUpButton!
    var speechChoiceLabel: NSTextField!
    var speechInfo: NSTextField!
    var privacyInfo: NSTextField!
    var owner: NSTextField!
    var conversation: NSPopUpButton!
    var summary: NSPopUpButton!
    var transcription: NSPopUpButton!
    var speed: NSSlider!
    var speedLabel: NSTextField!
    var speedTitle: NSTextField!
    var noiseGate: NSButton!
    var feedback: NSTextField!
    var keyStatus: NSTextField!
    var anthropicKey: NSSecureTextField!
    var openAIKey: NSSecureTextField!
    var deepgramKey: NSSecureTextField!
    var googleKey: NSSecureTextField!

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
    func secret(y: CGFloat, placeholder: String, x: CGFloat = 220, width: CGFloat = 356) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: x, y: y, width: width, height: 26))
        field.placeholderString = placeholder; window.contentView!.addSubview(field); return field
    }
    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 715), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Asistan — Modeller ve API anahtarları"; window.isReleasedWhenClosed = false
        _ = label("Görüşme ve özet için model seçin", y: 664, bold: true, height: 26)
        fieldLabel("Ses modu", y: 618)
        mode = popup(y: 618, items: [("Yerel ses — mevcut sistem", "local"), ("Çevrimiçi ses — GPT-Live 1", "gpt-live"), ("Çevrimiçi ses — Gemini 3.8 Live", "gemini-live|gemini-3.8-live"),
                                     ("Çevrimiçi ses — Gemini 3.1 Flash Live (eski önizleme)", "gemini-live|gemini-3.1-flash-live-preview")])
        mode.target = self; mode.action = #selector(updateMode)
        fieldLabel("Adına konuştuğu kişi", y: 568)
        owner = NSTextField(frame: NSRect(x: 220, y: 568, width: 356, height: 26)); window.contentView!.addSubview(owner)
        let models = BetaModelChoice.options.map { ($0.title, $0.choice.selection) }
        fieldLabel("Görüşme / arka plan", y: 522); conversation = popup(y: 522, items: models)
        fieldLabel("Özet modeli", y: 480); summary = popup(y: 480, items: [("Görüşme modeliyle aynı", "")] + models)
        _ = label("OpenAI için önce Luna’yı deneyin. Sol 6.1 düşünme kullandığı için daha geç yanıt verebilir. Her modelin hesap erişimi ve API ücreti farklıdır.", y: 426)
        speechChoiceLabel = fieldLabel("Konuşmayı yazıya çevirme", y: 392)
        // Item ids are "<STT_BACKEND>|<WHISPER_MODEL>"; Apple and Deepgram keep the saved Whisper model.
        transcription = popup(y: 392, items: [("Whisper Large v3 Turbo — hızlı", "mlx|mlx-community/whisper-large-v3-turbo"), ("Whisper Large v3 — daha büyük", "mlx|mlx-community/whisper-large-v3-mlx"),
                                              ("Apple SpeechAnalyzer — Türkçe dikte", "apple|"), ("Deepgram Nova-3 Türkçe — bulut", "deepgram|")])
        transcription.target = self; transcription.action = #selector(updateMode)
        liveVoice = popup(y: 392, items: BetaModelConfiguration.liveVoices.map { ($0 == "marin" ? "Marin — varsayılan" : $0.capitalized, $0) })
        liveVoice.isHidden = true; liveVoice.target = self; liveVoice.action = #selector(updateMode)
        geminiVoice = popup(y: 392, items: BetaModelConfiguration.geminiVoices.map { ($0 == "Kore" ? "Kore — varsayılan" : $0, $0) })
        geminiVoice.isHidden = true
        speechInfo = label("Yerel mod: Whisper ve EMA Lightning bu Mac’te çalışır.", y: 348, height: 34)
        speedTitle = fieldLabel("Konuşma hızı", y: 311)
        noiseGate = NSButton(checkboxWithTitle: "Arka plan gürültüsünü bastır (önerilir)", target: nil, action: nil)
        noiseGate.frame = NSRect(x: 220, y: 311, width: 356, height: 24); noiseGate.isHidden = true
        noiseGate.toolTip = "Arayan konuşmazken trafik gibi gürültü OpenAI'ye gönderilmez; model uydurma cümleler üretmez."
        window.contentView!.addSubview(noiseGate)
        speed = NSSlider(value: 1, minValue: 0.85, maxValue: 1.2, target: self, action: #selector(updateSpeed))
        speed.frame = NSRect(x: 220, y: 311, width: 274, height: 24); window.contentView!.addSubview(speed)
        speedLabel = NSTextField(labelWithString: "1,00×"); speedLabel.frame = NSRect(x: 508, y: 311, width: 68, height: 20); window.contentView!.addSubview(speedLabel)
        _ = label("API anahtarları", y: 263, bold: true, height: 26)
        fieldLabel("Anthropic anahtarı", y: 231); anthropicKey = secret(y: 231, placeholder: "Yeni anahtar; boşsa mevcut korunur")
        fieldLabel("OpenAI anahtarı", y: 193); openAIKey = secret(y: 193, placeholder: "sk-…; boşsa mevcut korunur")
        fieldLabel("Deepgram / Gemini anahtarı", y: 155)
        deepgramKey = secret(y: 155, placeholder: "Deepgram", width: 174); googleKey = secret(y: 155, placeholder: "Gemini (AIza…)", x: 402, width: 174)
        keyStatus = label("", y: 118, height: 32)
        privacyInfo = label("Anahtarları yalnızca buraya girin; sohbetten paylaşmanız gerekmez. Kaydetme görüşme yokken uygulanır. Metin ve talimatlar seçtiğiniz sağlayıcıya gönderilir; ham ses bu Mac’te işlenir.", y: 72, height: 46)
        feedback = label("", y: 44, height: 28)
        let save = NSButton(title: "Kaydet ve uygula", target: self, action: #selector(save)); save.bezelStyle = .rounded
        save.frame = NSRect(x: 396, y: 10, width: 180, height: 32); window.contentView!.addSubview(save)
    }
    func choose(_ popup: NSPopUpButton, id: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == id }) { popup.select(item) }
        else { popup.addItem(withTitle: id); popup.lastItem?.representedObject = id; popup.select(popup.lastItem) }
    }
    @objc func updateMode() {
        let selected = String((mode.selectedItem?.representedObject as? String ?? "local").split(separator: "|").first ?? "local")
        let online = selected != "local", gemini = selected == "gemini-live"
        let backend = (transcription.selectedItem?.representedObject as? String ?? "mlx|").split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? "mlx"
        transcription.isEnabled = !online; transcription.isHidden = online
        liveVoice.isEnabled = online && !gemini; liveVoice.isHidden = !online || gemini
        geminiVoice.isEnabled = gemini; geminiVoice.isHidden = !gemini
        speechChoiceLabel.stringValue = gemini ? "Gemini sesi" : (online ? "GPT-Live sesi" : "Konuşmayı yazıya çevirme")
        speed.isEnabled = !online; speed.isHidden = online; speedLabel.isHidden = online
        noiseGate.isHidden = !online; speedTitle.stringValue = online ? "Gürültü" : "Konuşma hızı"
        if gemini {
            speechInfo.stringValue = "Gemini Live dinler ve konuşur; Türkçe resmî olarak destekli. 3.8 Google’ın kararlı modeli, 3.1 eski önizleme. Görüşme modeli gerektiğinde arka planda yanıt verir."
            privacyInfo.stringValue = "Gemini modunda görüşme sesi Google’a gider. Ses yaklaşık $0,02–0,03/dk; arka plan ve özet ayrıca ücretlenir. Gemini anahtarını Google AI Studio’dan alın."
        } else if online {
            speechInfo.stringValue = "GPT-Live 1 dinler ve konuşur; Whisper/EMA kullanılmaz. Ses seçimi yeni görüşmede uygulanır. Görüşme modeli, gerektiğinde arka planda yanıt verir."
            privacyInfo.stringValue = "GPT-Live modunda görüşme sesi OpenAI’ye gider. Ses oturumu $0,05/dk; arka plan ve özet ayrıca ücretlenir. Anahtarı buraya girin. Değişiklik görüşme yokken uygulanır."
        } else {
            speechInfo.stringValue = ["apple": "Apple’ın Türkçe dikte modeli bu Mac’te çalışır (macOS 26 ve sonrası); ilk kullanımda indirilir. Konuşan ses EMA Lightning.",
                                      "deepgram": "Deepgram Nova-3 arayanın sözlerini bulutta yazıya çevirir (yaklaşık $0,005–0,008/dk). Konuşan ses EMA Lightning, bu Mac’te."][backend]
                ?? "Yerel mod: Whisper ve EMA Lightning bu Mac’te çalışır. Model değişikliği indirme gerektirebilir."
            privacyInfo.stringValue = backend == "deepgram" ? "Deepgram seçiliyken arayanın sesi yazıya çevrilmek için Deepgram’a gider. Metin ve talimatlar seçilen dil modeline gider. Boş anahtar alanı mevcut anahtarı korur."
                : "Anahtarları buraya girin. Metin ve talimatlar seçilen sağlayıcıya gider; ham ses bu Mac’te işlenir. Boş anahtar alanı mevcut anahtarı korur."
        }
    }
    @objc func updateSpeed() { speedLabel.stringValue = String(format: "%.2f×", speed.doubleValue) }
    func refreshKeys(_ values: [String: String]) {
        let saved = ["anthropic", "openai", "deepgram", "google"].map { provider in
            BetaModelConfiguration.providerTitle(provider) + " " + ((values[BetaModelConfiguration.credentialKeys[provider]!]?.count ?? 0) > 20 ? "✓" : "yok")
        }
        keyStatus.stringValue = "Kayıtlı anahtar: " + saved.joined(separator: " · ") + " — bağlantıyı kurulum ekranından sınayın."
    }
    func paneClosed() {}
    func prepare() {
        let values = app.savedSettings()
        owner.stringValue = values["OWNER_NAME"] ?? "Mehmet"
        let voiceMode = (try? BetaModelConfiguration.voiceMode(in: values)) ?? "local"
        choose(mode, id: voiceMode == "gemini-live" ? "gemini-live|" + ((try? BetaModelConfiguration.geminiModel(in: values)) ?? "gemini-3.8-live") : voiceMode)
        choose(liveVoice, id: (try? BetaModelConfiguration.liveVoice(in: values)) ?? "marin")
        choose(geminiVoice, id: (try? BetaModelConfiguration.geminiVoice(in: values)) ?? "Kore")
        let backend = (try? BetaModelConfiguration.speechBackend(in: values)) ?? "mlx"
        choose(transcription, id: ["apple", "deepgram"].contains(backend) ? backend + "|" : "mlx|" + (values["WHISPER_MODEL"] ?? "mlx-community/whisper-large-v3-turbo"))
        updateMode()
        do {
            let choices = try BetaModelConfiguration.choices(in: values)
            choose(conversation, id: choices.conversation.selection)
            choose(summary, id: (values["SUMMARY_MODEL"] ?? "").isEmpty && (values["SUMMARY_PROVIDER"] ?? "").isEmpty ? "" : choices.summary.selection)
            feedback.stringValue = ""
        } catch { feedback.stringValue = error.localizedDescription }
        speed.doubleValue = min(1.2, max(0.85, Double(values["TTS_SPEED"] ?? "1") ?? 1)); updateSpeed()
        noiseGate.state = (values["LIVE_NOISE_GATE"] ?? "on").lowercased() == "off" ? .off : .on
        for field in [anthropicKey, openAIKey, deepgramKey, googleKey] { field?.stringValue = "" }; refreshKeys(values)
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
            let speech = (transcription.selectedItem!.representedObject as! String).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let whisper = speech[1].isEmpty ? (BetaModelConfiguration.values(in: previous)["WHISPER_MODEL"] ?? "mlx-community/whisper-large-v3-turbo") : speech[1]
            let voice = (mode.selectedItem!.representedObject as! String).split(separator: "|").map(String.init)
            var changes = ["VOICE_MODE": voice[0], "GEMINI_LIVE_MODEL": voice.count > 1 ? voice[1] : (BetaModelConfiguration.values(in: previous)["GEMINI_LIVE_MODEL"] ?? ""), "GPT_LIVE_VOICE": liveVoice.selectedItem!.representedObject as! String,
                           "GEMINI_LIVE_VOICE": geminiVoice.selectedItem!.representedObject as! String, "OWNER_NAME": name, "LLM_PROVIDER": selected.provider,
                           "SUMMARY_PROVIDER": selectedSummary?.provider ?? "", "SUMMARY_MODEL": selectedSummary?.model ?? "",
                           "WHISPER_MODEL": whisper, "STT_BACKEND": speech[0], "TTS_SPEED": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), speed.doubleValue),
                           "LIVE_NOISE_GATE": noiseGate.state == .on ? "on" : "off"]
            changes[selected.provider == "openai" ? "OPENAI_MODEL" : "CLAUDE_MODEL"] = selected.model
            var updated = try BetaModelConfiguration.updating(previous, with: changes)
            let credentials = ["ANTHROPIC_API_KEY": anthropicKey, "OPENAI_API_KEY": openAIKey, "DEEPGRAM_API_KEY": deepgramKey, "GEMINI_API_KEY": googleKey]
                .mapValues { $0!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
            if !credentials.isEmpty { updated = try BetaModelConfiguration.updatingCredentials(updated, with: credentials) }
            let missing = try BetaModelConfiguration.missingCredentials(in: BetaModelConfiguration.values(in: updated))
            guard missing.isEmpty else { feedback.stringValue = "Seçtiğiniz modeller için " + missing.map(BetaModelConfiguration.providerTitle).joined(separator: " ve ") + " anahtarı girin. Mevcut ayarlar korunuyor."; return }
            try updated.write(to: env, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.path)
            for field in [anthropicKey, openAIKey, deepgramKey, googleKey] { field?.stringValue = "" }; refreshKeys(BetaModelConfiguration.values(in: updated))
            app.setupController?.invalidateAPICheck()
            if app.setupStatus().py { app.restartAgent() }
            feedback.stringValue = "Kaydedildi. Seçtiğiniz modellerin bağlantısını kurulum ekranından sınayabilirsiniz."
        } catch { feedback.stringValue = "Ayarlar kaydedilemedi: " + error.localizedDescription }
    }
}

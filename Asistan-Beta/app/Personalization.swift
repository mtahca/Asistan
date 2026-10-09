import Cocoa

final class PersonalizationController: NSObject {
    let app: AppDelegate
    var window: NSWindow!
    var editors: [String: NSTextView] = [:]
    var feedback: NSTextField!
    var dateLabel: NSTextField!
    var loadedDate = ""
    var canSave = true
    var preferencesURL: URL { app.projectDir.appendingPathComponent("asistan_tercihleri.json") }

    init(app: AppDelegate) { self.app = app; super.init(); build() }
    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 455), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Asistan Beta — Kişiselleştirme"; window.isReleasedWhenClosed = false
        let content = window.contentView!
        let tabs = NSTabView(frame: NSRect(x: 20, y: 105, width: 540, height: 330))
        for (key, title, hint) in [
            ("general", "Genel talimat", "Kalıcı konuşma tercihlerinizi ve iletilmesini istediğiniz bilgileri yazın. En fazla 8000 karakter."),
            ("today", "Bugünün notu", "Yalnızca bugün geçerli bilgi. Yarın yeni aramalarda kullanılmaz. En fazla 4000 karakter."),
            ("greeting", "Karşılama", "Boş bırakırsanız mevcut karşılama kullanılır. Özel metninizde yapay zekâ asistanı olduğunu belirtin. En fazla 500 karakter."),
            ("aliases", "Hitaplar", "Her satıra ekranda görünen adı ve hitabı yazın: Aşkım=Ayşe Hanım. Yalnızca tam ad eşleşir; ad veya cinsiyet tahmin edilmez.")
        ] {
            let item = NSTabViewItem(identifier: key); item.label = title
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 290))
            let label = NSTextField(wrappingLabelWithString: hint)
            label.frame = NSRect(x: 12, y: 220, width: 496, height: 58); view.addSubview(label)
            let scroll = NSScrollView(frame: NSRect(x: 12, y: 48, width: 496, height: 168))
            scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            let editor = NSTextView(frame: scroll.bounds)
            editor.isRichText = false; editor.font = .systemFont(ofSize: 13)
            editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
            editor.isVerticallyResizable = true; editor.textContainer?.widthTracksTextView = true
            editor.autoresizingMask = [.width]; editor.textContainerInset = NSSize(width: 8, height: 8)
            scroll.documentView = editor; view.addSubview(scroll); editors[key] = editor
            if key == "today" {
                dateLabel = NSTextField(labelWithString: "")
                dateLabel.frame = NSRect(x: 12, y: 15, width: 315, height: 22); view.addSubview(dateLabel)
                let clear = NSButton(title: "Bugünün notunu temizle", target: self, action: #selector(clearToday))
                clear.bezelStyle = .rounded; clear.frame = NSRect(x: 320, y: 10, width: 190, height: 30); view.addSubview(clear)
            }
            item.view = view; tabs.addTabViewItem(item)
        }
        content.addSubview(tabs)
        feedback = NSTextField(wrappingLabelWithString: "")
        feedback.frame = NSRect(x: 20, y: 45, width: 540, height: 52); content.addSubview(feedback)
        let save = NSButton(title: "Kaydet", target: self, action: #selector(save))
        save.bezelStyle = .rounded; save.frame = NSRect(x: 430, y: 10, width: 130, height: 30); content.addSubview(save)
    }
    func show() {
        do {
            let prefs = try AssistantPreferences.load(from: preferencesURL)
            editors["general"]?.string = prefs.general
            editors["today"]?.string = prefs.todayDate == AssistantPreferences.dateKey() ? prefs.today : ""
            editors["greeting"]?.string = prefs.greeting
            editors["aliases"]?.string = prefs.aliases.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            loadedDate = AssistantPreferences.dateKey(); dateLabel.stringValue = "Geçerli tarih: " + loadedDate
            canSave = true; feedback.stringValue = "Kaydedilen tercihler bir sonraki aramada uygulanır. Etkin görüşme kendi ayarlarıyla devam eder."
        } catch {
            canSave = false; feedback.stringValue = "Ayarlar okunamadı; mevcut dosya korunuyor: " + error.localizedDescription
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func clearToday() { editors["today"]?.string = ""; feedback.stringValue = "Temizlemeyi uygulamak için Kaydet’e basın." }
    @objc func save() {
        guard canSave else { return }
        guard loadedDate == AssistantPreferences.dateKey() else {
            feedback.stringValue = "Tarih değişti. Pencereyi yeniden açıp bugünün notunu kontrol edin."; return
        }
        do {
            var prefs = AssistantPreferences()
            prefs.general = editors["general"]!.string.trimmingCharacters(in: .whitespacesAndNewlines)
            prefs.today = editors["today"]!.string.trimmingCharacters(in: .whitespacesAndNewlines)
            prefs.todayDate = prefs.today.isEmpty ? "" : loadedDate
            prefs.greeting = editors["greeting"]!.string.trimmingCharacters(in: .whitespacesAndNewlines)
            prefs.aliases = try AssistantPreferences.parseAliases(editors["aliases"]!.string)
            try prefs.save(to: preferencesURL)
            feedback.stringValue = "Kaydedildi. Bir sonraki aramada uygulanacak."
        } catch { feedback.stringValue = error.localizedDescription }
    }
}

import Foundation

struct BetaModelChoice: Equatable {
    let provider: String
    let model: String
    var selection: String { provider + ":" + model }
    var providerTitle: String { provider == "openai" ? "OpenAI" : "Anthropic" }
    var display: String { Self.options.first { $0.choice == self }?.title ?? model }
    static let options: [(title: String, choice: BetaModelChoice)] = [
        ("Claude Haiku 4.5 — hızlı", Self(provider: "anthropic", model: "claude-haiku-4-5")),
        ("Claude Haiku 5.5 — hızlı, düşünme kapalı", Self(provider: "anthropic", model: "claude-haiku-5-5")),
        ("Claude Sonnet 5.5 — daha güçlü", Self(provider: "anthropic", model: "claude-sonnet-5-5")),
        ("OpenAI GPT-6 Luna — hızlı ve ekonomik", Self(provider: "openai", model: "gpt-6-luna")),
        ("OpenAI GPT-6 Sol — düşünme kapalı", Self(provider: "openai", model: "gpt-6-sol")),
        ("OpenAI GPT-6.1 Sol — daha kapsamlı", Self(provider: "openai", model: "gpt-6.1-sol"))
    ]
    static func parse(_ selection: String) throws -> Self {
        let parts = selection.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw BetaModelConfiguration.invalid("Geçersiz model seçimi.") }
        return try checked(provider: parts[0], model: parts[1])
    }
    static func checked(provider: String, model: String) throws -> Self {
        let choice = Self(provider: provider, model: model)
        guard (provider == "anthropic" && model.hasPrefix("claude-")) ||
              (provider == "openai" && options.contains(where: { $0.choice == choice })) else {
            throw BetaModelConfiguration.invalid("Model ve sağlayıcı eşleşmiyor. Model seçimini kontrol edin.")
        }
        return choice
    }
}

struct BetaModelConfiguration {
    // Official GPT-Live built-in names, checked 2026-10-09. Keep Python catalog in sync.
    static let liveVoices: [String] = ["marin", "cedar", "alloy", "ash", "ballad", "beacon", "bossa", "brise", "cinder", "coral", "delta", "echo", "flitz", "gleam", "harema", "juni", "meridian", "nira", "noeul", "nuri", "quartz", "ripple", "sage", "shida", "shimmer", "sillage", "stone", "tempo", "verse", "vesper", "willow"]
    static func liveVoice(in values: [String: String]) throws -> String {
        let voice = values["GPT_LIVE_VOICE"].flatMap { $0.isEmpty ? nil : $0 } ?? "marin"
        guard liveVoices.contains(voice) else { throw invalid("GPT-Live sesi geçersiz. Ayarlardan desteklenen bir ses seçin.") }
        return voice
    }

    static func voiceMode(in values: [String: String]) throws -> String {
        let mode = values["VOICE_MODE"].flatMap { $0.isEmpty ? nil : $0 } ?? "local"
        guard ["local", "gpt-live"].contains(mode) else { throw invalid("Ses modu geçersiz.") }
        return mode
    }
    static func requiredProviders(in values: [String: String]) throws -> [String] {
        let selected = try choices(in: values)
        var providers = Set([selected.conversation.provider, selected.summary.provider])
        if try voiceMode(in: values) == "gpt-live" { _ = try liveVoice(in: values); providers.insert("openai") }
        return providers.sorted()
    }
    static let editableKeys: Set<String> = ["VOICE_MODE", "GPT_LIVE_VOICE", "OWNER_NAME", "LLM_PROVIDER", "CLAUDE_MODEL", "OPENAI_MODEL", "SUMMARY_PROVIDER", "SUMMARY_MODEL", "WHISPER_MODEL", "STT_BACKEND", "TTS_SPEED", "LIVE_NOISE_GATE"]
    static let credentialKeys = ["anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY"]
    static func invalid(_ text: String) -> NSError {
        NSError(domain: "Asistan", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func choices(in values: [String: String]) throws -> (conversation: BetaModelChoice, summary: BetaModelChoice) {
        let provider = values["LLM_PROVIDER"].flatMap { $0.isEmpty ? nil : $0 } ?? "anthropic"
        let modelKey = provider == "openai" ? "OPENAI_MODEL" : "CLAUDE_MODEL"
        let defaultModel = provider == "openai" ? "gpt-6-luna" : "claude-haiku-4-5"
        let conversation = try BetaModelChoice.checked(provider: provider, model: values[modelKey].flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel)
        let summaryProvider = values["SUMMARY_PROVIDER"].flatMap { $0.isEmpty ? nil : $0 } ?? provider
        let summaryDefault = summaryProvider == provider ? conversation.model : (summaryProvider == "openai" ? "gpt-6-luna" : "claude-haiku-4-5")
        let summary = try BetaModelChoice.checked(provider: summaryProvider, model: values["SUMMARY_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? summaryDefault)
        return (conversation, summary)
    }
    static func missingCredentials(in values: [String: String]) throws -> [String] {
        return try requiredProviders(in: values).filter {
            (values[credentialKeys[$0]!]?.count ?? 0) <= 20
        }
    }
    static func updatingCredentials(_ text: String, with changes: [String: String]) throws -> String {
        guard changes.keys.allSatisfy({ credentialKeys.values.contains($0) }),
              changes.values.allSatisfy({ $0.count > 20 && $0.count <= 1024 &&
                  !$0.contains(where: { $0.isWhitespace || $0 == "\0" || $0 == "\"" || $0 == "'" }) }) else {
            throw invalid("Anahtar geçersiz görünüyor. Boşluk veya satır sonu olmadan yeniden girin.")
        }
        return replace(text, with: changes)
    }
    static func values(in text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let split = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<split]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }
        return values
    }
    static func updating(_ text: String, with changes: [String: String]) throws -> String {
        guard changes.keys.allSatisfy({ editableKeys.contains($0) }),
              changes.values.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") }) else {
            throw NSError(domain: "Asistan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Geçersiz model ayarı."])
        }
        if let voice = changes["GPT_LIVE_VOICE"] { _ = try liveVoice(in: ["GPT_LIVE_VOICE": voice]) }
        return replace(text, with: changes)
    }
    private static func replace(_ text: String, with changes: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n").filter { line in
            guard let split = line.firstIndex(of: "=") else { return true }
            let key = String(line[..<split]).trimmingCharacters(in: .whitespaces)
            return changes[key] == nil
        }
        while lines.last == "" { lines.removeLast() }
        lines += changes.keys.sorted().map { "\($0)=\(changes[$0]!)" }
        return lines.joined(separator: "\n") + "\n"
    }
}

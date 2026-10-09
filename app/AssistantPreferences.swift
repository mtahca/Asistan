import Foundation

/// Separate from credentials. Empty values preserve the established call behavior.
struct AssistantPreferences: Codable, Equatable {
    var version = 1
    var general = ""
    var today = ""
    var todayDate = ""
    var greeting = ""
    var aliases: [String: String] = [:]

    static func dateKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "tr_TR"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func parseAliases(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw invalid("Her hitabı ayrı satıra Ekrandaki ad=Hitap biçiminde yazın.") }
            let key = normalized(String(parts[0]))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, key.count <= 160, value.count <= 80,
                  !value.contains("="), !key.contains("\0"), !value.contains("\0") else {
                throw invalid("Hitaplarda boş ad veya hitap kullanmayın. Ad en fazla 160, hitap 80 karakter olabilir.")
            }
            guard result[key] == nil else { throw invalid("Aynı ekran adına birden fazla hitap yazılmış: " + key) }
            result[key] = value
        }
        guard result.count <= 30 else { throw invalid("En fazla 30 kişiye özel hitap ekleyebilirsiniz.") }
        return result
    }
    func validated() throws -> AssistantPreferences {
        guard version == 1 else { throw Self.invalid("Bu ayar dosyasının sürümü desteklenmiyor.") }
        for (text, limit, title) in [(general, 8000, "Genel talimat"), (today, 4000, "Bugünün notu"), (greeting, 500, "Karşılama")] {
            guard text.unicodeScalars.count <= limit, !text.contains("\0") else { throw Self.invalid("\(title) en fazla \(limit) karakter olabilir.") }
        }
        if !today.isEmpty {
            guard todayDate.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
                throw Self.invalid("Bugünün notunun tarihi geçersiz.")
            }
        }
        guard !aliases.contains(where: { pair in
            (pair.key + pair.value).contains(where: { $0 == "\n" || $0 == "\r" || $0 == "=" || $0 == "\0" })
        }) else { throw Self.invalid("Hitaplarda satır sonu veya eşittir işareti kullanılamaz.") }
        _ = try Self.parseAliases(aliases.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        return self
    }
    static func load(from url: URL) throws -> AssistantPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return AssistantPreferences() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).validated()
    }
    func save(to url: URL) throws {
        let value = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func invalid(_ text: String) -> NSError {
        NSError(domain: "AsistanPreferences", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

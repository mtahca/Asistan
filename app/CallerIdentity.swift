import Foundation

struct CallerInfo {
    var name: String = ""
    var number: String = ""
    var inContacts = false
}

enum CallerAttribute { case title, description, help, value, identifier }
struct CallerLabel {
    var role: String
    var attribute: CallerAttribute
    var value: String
}

/// Preserve the identity captured while ringing; use only the same source's
/// active call when that snapshot contained no identity at all.
func callerAfterConnection(incoming: CallerInfo, connected: CallerInfo) -> CallerInfo {
    incoming.name.isEmpty && incoming.number.isEmpty ? connected : incoming
}

func looksLikeNumber(_ text: String) -> Bool {
    text.filter { $0.isNumber }.count >= 7 &&
        text.allSatisfy { $0.isNumber || " +-()\u{A0}".contains($0) }
}

func extractCaller(from labels: [CallerLabel], source: CallSource) -> CallerInfo {
    func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter {
            ![0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(Int($0.value))
        }
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let excluded = Set(["whatsapp", "whatsapp audio call", "whatsapp voice call", "whatsapp video call",
        "facetime", "facetime audio", "facetime video", "phone", "telefon", "audio", "video",
        "incoming call", "incoming voice call", "incoming audio call", "gelen arama", "gelen sesli arama",
        "accept", "accept call", "answer", "decline", "hang up", "leave call", "end call",
        "kabul", "kabul et", "yanıtla", "cevapla", "reddet", "mute", "mute off", "muted",
        "mobile", "cellular", "ses", "arama", "unknown", "unknown caller", "no caller id",
        "bilinmeyen", "bilinmeyen arayan", "özel numara", "from your iphone", "iphone’unuzdan", "iphone'unuzdan",
        "recents", "recent calls", "contacts", "favorites", "son aramalar", "kişiler", "favoriler", "scenewindow"])
    func candidate(_ text: String) -> String? {
        let text = clean(text)
        guard !text.isEmpty, text.count <= 160, !excluded.contains(text.lowercased()) else { return nil }
        guard looksLikeNumber(text) || text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
        return text
    }
    let content = labels.filter { $0.attribute != .identifier && $0.attribute != .help }
    var info = CallerInfo()
    func assign(_ text: String) {
        guard let value = candidate(text) else { return }
        if looksLikeNumber(value) { if info.number.isEmpty { info.number = value } }
        else if info.name.isEmpty { info.name = value }
    }
    // WhatsApp exposes the caller in the call-owned window title. Never use
    // the window's AXIdentifier (SceneWindow) or a generic app window title.
    if source == .whatsapp {
        for label in content where label.role == "AXWindow" && label.attribute == .title {
            let text = clean(label.value)
            for suffix in [" - WhatsApp voice call", " - WhatsApp audio call", " - WhatsApp video call"] {
                if let range = text.range(of: suffix, options: [.caseInsensitive, .backwards]), range.upperBound == text.endIndex {
                    assign(String(text[..<range.lowerBound]))
                }
            }
        }
    }
    // Caller content comes from text elements, never buttons, help text or IDs.
    for label in content where ["AXStaticText", "AXTextField", "AXHeading"].contains(label.role) {
        let text = clean(label.value)
        var who = text
        // Apple notifications may combine the caller and call source in one label.
        if source == .apple, let range = text.range(of: ", ", options: .backwards) {
            let tail = text[range.upperBound...].lowercased()
            if ["facetime", "iphone", "audio", "video", "mobile", "cellular", "telefon", "phone", "arama"].contains(where: tail.contains) {
                who = String(text[..<range.lowerBound])
            }
        }
        assign(who)
    }
    // SwiftUI may expose a combined caller/type label on a group instead of
    // an individual text element. Only accept an explicit call-type suffix.
    if source == .apple && info.name.isEmpty && info.number.isEmpty {
        let types = Set(["facetime", "facetime audio", "facetime video", "from your iphone",
            "iphone’unuzdan", "iphone'unuzdan", "phone", "telefon", "mobile", "cellular",
            "gelen arama", "gelen sesli arama", "sesli arama"])
        for label in content where label.role == "AXGroup" && [.description, .value, .title].contains(label.attribute) {
            let text = clean(label.value)
            if let range = text.range(of: ", ", options: .backwards), types.contains(String(text[range.upperBound...]).lowercased()) {
                assign(String(text[..<range.lowerBound]))
            }
        }
    }
    return info
}

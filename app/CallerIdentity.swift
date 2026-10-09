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
        // Notification Center wraps names in directional marks and uses no-break spaces
        // ("FaceTime\u{A0}Audio"); normalise both so plain comparisons work.
        let scalars: [Unicode.Scalar] = text.unicodeScalars.compactMap {
            if [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(Int($0.value)) { return nil }
            if [0x00A0, 0x2007, 0x202F, 0x2009, 0x200A, 0x2002, 0x2003].contains(Int($0.value)) { return " " }
            return $0
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
    // Notification Center exposes banner content on AXUnknown/AXGroup elements, as one
    // "Name, FaceTime Audio" label, as "Name\nFaceTime Audio", or as separate elements.
    // Only accept text that sits next to an explicit call-type label.
    if source == .apple && info.name.isEmpty && info.number.isEmpty {
        let types = Set(["facetime", "facetime audio", "facetime video", "from your iphone", "from iphone",
            "iphone’unuzdan", "iphone'unuzdan", "phone", "telefon", "mobile", "cellular",
            "gelen arama", "gelen sesli arama", "sesli arama", "incoming call", "audio", "video"])
        func isType(_ part: String) -> Bool {
            let text = part.lowercased()
            return types.contains(text) || ["facetime", "iphone"].contains(where: text.contains)
        }
        let controls = Set(["AXButton", "AXMenuButton", "AXPopUpButton", "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXWindow", "AXApplication"])
        let visible = content.filter { !controls.contains($0.role) && [.description, .value, .title].contains($0.attribute) }
        // One element carrying both parts.
        for label in visible {
            let parts = clean(label.value).components(separatedBy: CharacterSet.newlines).flatMap { $0.components(separatedBy: ", ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard parts.count >= 2, parts.contains(where: isType) else { continue }
            for part in parts where !isType(part) { assign(part) }
            if !info.name.isEmpty || !info.number.isEmpty { return info }
        }
        // Separate elements, accepted only inside a notification banner subtree.
        let banner = labels.contains { $0.attribute == .identifier && $0.value.lowercased().contains("notification") }
        if banner, visible.contains(where: { isType(clean($0.value)) }) {
            for label in visible where !isType(clean(label.value)) { assign(label.value) }
        }
    }
    return info
}

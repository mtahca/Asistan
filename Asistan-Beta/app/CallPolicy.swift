import Foundation

enum CallSource: String {
    case apple = "FaceTime / Telefon"
    case whatsapp = "WhatsApp"
    var bundleIDs: [String] {
        self == .whatsapp ? ["net.whatsapp.WhatsApp"] : ["com.apple.FaceTime", "com.apple.mobilephone"]
    }
}

enum CallUI {
    static func normalized(_ text: String) -> String {
        let filtered = text.unicodeScalars.filter {
            ![0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(Int($0.value))
        }
        return String(String.UnicodeScalarView(filtered)).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func answer(_ text: String) -> Bool {
        ["answer", "accept", "accept call", "answer call", "kabul", "kabul et", "yanıtla", "yanitla", "cevapla", "aramayı cevapla", "aramayı yanıtla", "accept_call", "answer_call", "callui_acceptbutton"].contains(normalized(text))
    }
    static func decline(_ text: String) -> Bool {
        ["decline", "reject", "decline call", "reddet", "aramayı reddet", "decline_call", "callui_declinebutton"].contains(normalized(text))
    }
    static func end(_ text: String) -> Bool {
        ["end", "end call", "hang up", "leave call", "aramayı bitir", "aramayı sonlandır", "görüşmeyi bitir", "bitir", "end_call", "hang_up"].contains(normalized(text))
    }
    static func appleNotification(_ text: String) -> Bool {
        let t = normalized(text)
        return ["facetime_notification", "facetime notification", "phone_notification", "phone notification"].contains { t.contains($0) }
    }
    static func videoCall(_ texts: [String]) -> Bool {
        texts.map(normalized).contains { t in
            ["incoming video call", "facetime video", "görüntülü arama", "video call incoming", "whatsapp video call"].contains(where: t.contains)
        }
    }
    static func voiceIncoming(_ texts: [String]) -> Bool {
        let values = texts.map(normalized)
        if videoCall(texts) { return false }
        // Observed WhatsApp macOS UI: an audio header and a pair of call-specific
        // accept/decline IDs. It has no separate "incoming" label.
        if values.contains("callui_acceptbutton") && values.contains("callui_declinebutton") &&
           values.contains("whatsapp audio call") { return true }
        return values.contains { t in
            ["incoming call", "incoming voice call", "incoming audio call", "gelen arama", "gelen sesli arama"].contains { t.contains($0) }
                && !t.hasPrefix("start ") && !t.hasPrefix("başlat")
        }
    }
    static func connectedEndControl(_ buttonTexts: [String], rootHasAnswer: Bool, rootHasDecline: Bool) -> Bool {
        // WhatsApp's incoming decline button is also described as "hang up".
        // Treat it as an active call control only when the incoming pair is gone.
        !(rootHasAnswer && rootHasDecline) && buttonTexts.contains(where: end)
    }

}

enum BetaAudio {
    static let listenName = "Asistan Dinleme"
    static let microphoneName = "Asistan Mikrofonu"
    static let playbackName = "Asistan Ses Çıkışı"
}

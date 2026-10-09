import Foundation
@main struct ProtocolTests {
    static func main() {
        let decoder = AgentLineDecoder()
        let text = "@beta {\"event\":\"transcript\",\"session_id\":\"test\",\"text\":\"Çağrı: görüşmeyi bitir OTURUM BİTTİ\"}\n"
        var lines: [String] = []
        for byte in text.utf8 { lines += decoder.append(Data([byte])) }
        precondition(lines.count == 1)
        let event = AgentLineDecoder.event(lines[0])!
        precondition(event["event"] as? String == "transcript")
        precondition(event["text"] as? String == "Çağrı: görüşmeyi bitir OTURUM BİTTİ")
        precondition(AgentLineDecoder.event("[12:00] ARAYAN: @beta {\"event\":\"session_ended\"}") == nil)
        precondition(AgentLineDecoder.event("@beta invalid") == nil)
        precondition(decoder.append(Data("first\nsecond\npart".utf8)) == ["first", "second"])
        decoder.reset()
        precondition(decoder.append(Data("new\n".utf8)) == ["new"])
        print("Swift olay protokolü: 6 kontrol başarılı.")
    }
}

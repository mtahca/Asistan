import Foundation
@main struct MobileFocusTests {
    static var count = 0
    static func check(_ value: Bool) { count += 1; precondition(value) }
    static func main() throws {
        check(LiveProtocol.serviceType == "_asistan-canli._tcp")
        check(LiveProtocol.port == 47821)
        check(LiveProtocol.version == 1)
        check(LiveProtocol.localAddresses().allSatisfy { !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.") && $0.split(separator: ".").count == 4 })
        check(LiveProtocol.serviceName(host: String(repeating: "🦊", count: 80)).utf8.count <= 63)
        check(LiveProtocol.serviceName(host: "Mehmet").hasSuffix(" — Asistan"))
        check(LiveProtocol.serviceName(host: "") == "Mac — Asistan")
        var decoder = MobileFrames(); var objects: [[String: Any]] = []
        let packet = LiveProtocol.encode(["t": "note", "text": "Merhaba 🌍\nBir dakika"] )!
        for byte in packet { objects += try decoder.consume(Data([byte])) }
        check(objects.count == 1)
        check(MobileCommand.parse(objects[0]) == .note("Merhaba 🌍\nBir dakika"))
        check(try decoder.consume(Data("{\"t\":\"ping\"}\n{\"t\":\"answer\"}\n".utf8)).count == 2)
        var tooBig = MobileFrames()
        do { _ = try tooBig.consume(Data(repeating: 65, count: MobileFrames.limit + 1)); check(false) } catch { check(true) }
        var malformed = MobileFrames()
        do { _ = try malformed.consume(Data("[]\n".utf8)); check(false) } catch { check(true) }
        check(MobileCommand.parse(["t": "shutdown"]) == nil)
        check(MobileCommand.parse(["t": "note", "text": "  "]) == nil)
        check(MobileCommand.parse(["t": "note", "text": String(repeating: "a", count: 1001)]) == nil)
        check(MobileCommand.parse(["t": "note", "text": String(repeating: "a", count: 1000)]) != nil)
        check(!MobileCommand.answer.allowed(ringing: false, inSession: false, paused: false, stopping: false))
        check(!MobileCommand.answer.allowed(ringing: true, inSession: false, paused: true, stopping: false))
        check(!MobileCommand.answer.allowed(ringing: true, inSession: true, paused: false, stopping: false))
        check(MobileCommand.answer.allowed(ringing: true, inSession: false, paused: false, stopping: false))
        check(!MobileCommand.end.allowed(ringing: true, inSession: false, paused: false, stopping: false))
        check(MobileCommand.end.allowed(ringing: false, inSession: true, paused: true, stopping: false))
        check(!MobileCommand.end.allowed(ringing: false, inSession: true, paused: false, stopping: true))
        check(!MobileCommand.note("x").allowed(ringing: false, inSession: false, paused: false, stopping: false))
        check(MobileCommand.note("x").allowed(ringing: false, inSession: true, paused: false, stopping: false))
        var live = MobileTranscript()
        live.replace([("caller", "Arayan", "Merha")]); let first = live.lines[0]["id"] as! Int
        live.replace([("caller", "Arayan", "Merhaba")]); check(live.lines.count == 1)
        check(live.lines[0]["text"] as? String == "Merhaba")
        check(live.lines[0]["id"] as! Int != first)
        let stable = live.lines[0]["id"] as! Int
        live.replace([("caller", "Arayan", "Merhaba")]); check(live.lines[0]["id"] as! Int == stable)
        for _ in 0..<205 { _ = live.append(kind: "assistant", speaker: "Asistan", text: "Test") }
        check(live.lines.count == 200)
        live.replace((0..<200).map { _ in ("caller", "Arayan", String(repeating: "😀", count: 3000)) })
        check(live.lines.count < 200)
        check(LiveProtocol.encode(["t": "snapshot", "lines": live.lines])!.count <= 262144)
        live.reset(); check(live.lines.isEmpty)
        check(FocusPolicy.focused(Data("{\"data\":[]}".utf8)) == false)
        check(FocusPolicy.focused(Data("{\"data\":[{\"storeAssertionRecords\":[] }]}".utf8)) == false)
        check(FocusPolicy.focused(Data("{\"data\":[{\"storeAssertionRecords\":[{}]}]}".utf8)) == true)
        check(FocusPolicy.focused(Data("{}".utf8)) == nil)
        check(FocusPolicy.focused(Data("{\"data\":[{\"unknown\":true}]}".utf8)) == nil)
        check(FocusPolicy.focused(Data("malformed".utf8)) == nil)
        check(FocusPolicy.shouldAnswer(manualAuto: false, focusAuto: true, focused: true, paused: false))
        check(!FocusPolicy.shouldAnswer(manualAuto: false, focusAuto: true, focused: false, paused: false))
        check(!FocusPolicy.shouldAnswer(manualAuto: false, focusAuto: true, focused: nil, paused: false))
        check(!FocusPolicy.shouldAnswer(manualAuto: false, focusAuto: false, focused: true, paused: false))
        check(!FocusPolicy.shouldAnswer(manualAuto: true, focusAuto: true, focused: true, paused: true))
        check(FocusPolicy.shouldAnswer(manualAuto: true, focusAuto: false, focused: nil, paused: false))
        print("Mobil ve Odak: \(count) kontrol başarılı.")
    }
}

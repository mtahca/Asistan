import Foundation

@main struct CallerIdentityTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        func label(_ role: String, _ attribute: CallerAttribute, _ text: String) -> CallerLabel {
            CallerLabel(role: role, attribute: attribute, value: text)
        }
        let whatsapp = extractCaller(from: [
            label("AXWindow", .title, "‎Aşkım - WhatsApp voice call"),
            label("AXWindow", .identifier, "SceneWindow"),
            label("AXStaticText", .description, "‎Aşkım"),
            label("AXStaticText", .description, "‎WhatsApp audio call"),
            label("AXButton", .description, "‎Accept call"),
            label("AXButton", .identifier, "CallUI_AcceptButton")], source: .whatsapp)
        check(whatsapp.name == "Aşkım"); check(whatsapp.number.isEmpty)
        let unknown = extractCaller(from: [
            label("AXWindow", .title, "WhatsApp"),
            label("AXWindow", .identifier, "SceneWindow"),
            label("AXStaticText", .help, "Ayşe Yılmaz"),
            label("AXStaticText", .identifier, "+90 555 123 45 67"),
            label("AXButton", .description, "Ayşe Yılmaz"),
            label("AXStaticText", .value, "00:03"),
            label("AXStaticText", .description, "Unknown caller")], source: .whatsapp)
        check(unknown.name.isEmpty); check(unknown.number.isEmpty)
        let number = extractCaller(from: [label("AXWindow", .title, "‎+90 555 123 45 67 - WhatsApp voice call")], source: .whatsapp)
        check(number.number == "+90 555 123 45 67"); check(number.name.isEmpty)
        let fallback = extractCaller(from: [
            label("AXWindow", .title, "WhatsApp"),
            label("AXStaticText", .description, "WhatsApp audio call"),
            label("AXStaticText", .description, "Elif Yılmaz"),
            label("AXStaticText", .value, "+90 (555) 123 45 67")], source: .whatsapp)
        check(fallback.name == "Elif Yılmaz"); check(fallback.number == "+90 (555) 123 45 67")
        let hyphen = extractCaller(from: [label("AXWindow", .title, "Ömer - Ofis - WhatsApp voice call")], source: .whatsapp)
        check(hyphen.name == "Ömer - Ofis")
        let apple = extractCaller(from: [
            label("AXWindow", .identifier, "FACETIME_NOTIFICATION"),
            label("AXStaticText", .description, "‎Ayşe Yılmaz, From Your iPhone")], source: .apple)
        check(apple.name == "Ayşe Yılmaz"); check(apple.number.isEmpty)
        let appleNumber = extractCaller(from: [label("AXStaticText", .value, "+90 555 123 45 67, FaceTime Audio")], source: .apple)
        check(appleNumber.number == "+90 555 123 45 67"); check(appleNumber.name.isEmpty)
        let actualName = extractCaller(from: [label("AXStaticText", .value, "Ender Sesil")], source: .apple)
        check(actualName.name == "Ender Sesil")
        let noCaller = extractCaller(from: [
            label("AXStaticText", .description, "Incoming call"),
            label("AXStaticText", .description, "From Your iPhone"),
            label("AXStaticText", .description, "Özel Numara")], source: .apple)
        check(noCaller.name.isEmpty); check(noCaller.number.isEmpty)
        let heading = extractCaller(from: [
            label("AXHeading", .description, "Recents"),
            label("AXHeading", .description, "Deniz Taşçı"),
            label("AXStaticText", .description, "FaceTime Audio")], source: .apple)
        check(heading.name == "Deniz Taşçı")
        let group = extractCaller(from: [label("AXGroup", .description, "Deniz Taşçı, FaceTime Audio")], source: .apple)
        check(group.name == "Deniz Taşçı")
        let groupNumber = extractCaller(from: [label("AXGroup", .value, "+90 555 123 45 67, From Your iPhone")], source: .apple)
        check(groupNumber.number == "+90 555 123 45 67"); check(groupNumber.name.isEmpty)
        let unrelatedGroups = extractCaller(from: [
            label("AXGroup", .description, "Deniz Taşçı"),
            label("AXGroup", .description, "Deniz Taşçı, Outgoing  FaceTime Audio, 6 calls, 17:56, Call"),
            label("AXGroup", .help, "Deniz Taşçı, FaceTime Audio"),
            label("AXGroup", .identifier, "Deniz Taşçı, FaceTime Audio"),
            label("AXButton", .description, "Deniz Taşçı, FaceTime Audio"),
            label("AXStaticText", .value, "SceneWindow")], source: .apple)
        check(unrelatedGroups.name.isEmpty); check(unrelatedGroups.number.isEmpty)
        let whatsappGroup = extractCaller(from: [label("AXGroup", .description, "Deniz Taşçı, FaceTime Audio")], source: .whatsapp)
        check(whatsappGroup.name.isEmpty)
        let fallbackCaller = callerAfterConnection(incoming: CallerInfo(), connected: group)
        check(fallbackCaller.name == "Deniz Taşçı")
        let protectedName = callerAfterConnection(incoming: CallerInfo(name: "Ayşe Yılmaz"), connected: group)
        check(protectedName.name == "Ayşe Yılmaz")
        let protectedNumber = callerAfterConnection(incoming: CallerInfo(number: "+90 555 111 22 33"), connected: groupNumber)
        check(protectedNumber.number == "+90 555 111 22 33"); check(protectedNumber.name.isEmpty)
        let stillUnknown = callerAfterConnection(incoming: CallerInfo(), connected: CallerInfo())
        check(stillUnknown.name.isEmpty); check(stillUnknown.number.isEmpty)
        print("Arayan bilgisi: \(checks) kontrol başarılı.")
    }
}

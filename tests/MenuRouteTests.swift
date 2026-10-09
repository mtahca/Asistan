import Foundation
@main struct MenuRouteTests {
    static var count = 0
    static func check(_ value: Bool, line: Int = #line) {
        count += 1
        if !value { print("Menü ses seçimi: satır \(line) başarısız."); exit(1) }
    }
    static let mic = "Asistan Mikrofonu"
    static let assistant = ["Asistan Dinleme", "Asistan Mikrofonu", "Asistan Ses Çıkışı"]
    static func item(_ title: String, checked: Bool = false, enabled: Bool = true) -> MenuNode {
        MenuNode(title: title, enabled: enabled, checked: checked)
    }
    static func heading(_ title: String) -> MenuNode { MenuNode(title: title, enabled: false) }
    static func main() {
        // FaceTime "Video" / Phone "Audio": headed sections in one menu.
        let phone = [
            MenuNode(title: "Telefon", children: [item("Telefon Hakkında")]),
            MenuNode(title: "Audio", children: [
                heading("Microphone"), item("Use System Setting", checked: true), item("MacBook Air Microphone"), item(mic),
                item(""),
                heading("Output"), item("Use System Setting"), item("MacBook Air Speakers", checked: true), item(mic), item("Asistan Ses Çıkışı"),
            ]),
        ]
        var plan = MenuRoute.plan(phone, microphone: mic, assistantDevices: assistant, preferredOutput: "MacBook Air Speakers")
        check(plan.inputListed)
        check(plan.inputCurrent == "Use System Setting")
        check(!plan.inputReady)
        check(plan.inputPress == MenuChoice(path: [1, 3], title: mic))
        check(plan.outputCurrent == "MacBook Air Speakers")
        check(plan.outputPress == nil)

        // Already correct: nothing to press.
        var ready = phone
        ready[1].children[1].checked = false; ready[1].children[3].checked = true
        plan = MenuRoute.plan(ready, microphone: mic, assistantDevices: assistant, preferredOutput: nil)
        check(plan.inputReady && plan.inputPress == nil)

        // Speaker set to a virtual device: move it to the preferred physical speaker.
        var wrongOutput = phone
        wrongOutput[1].children[7].checked = false; wrongOutput[1].children[9].checked = true
        plan = MenuRoute.plan(wrongOutput, microphone: mic, assistantDevices: assistant, preferredOutput: "MacBook Air Speakers")
        check(plan.outputPress == MenuChoice(path: [1, 7], title: "MacBook Air Speakers"))
        plan = MenuRoute.plan(wrongOutput, microphone: mic, assistantDevices: assistant, preferredOutput: "Asistan Ses Çıkışı")
        check(plan.outputPress == MenuChoice(path: [1, 6], title: "Use System Setting"))

        // A later heading (Camera) ends the speaker list.
        let facetime = [MenuNode(title: "Video", children: [
            heading("Mikrofon"), item("MacBook Air Mikrofonu", checked: true), item(mic),
            heading("Kamera"), item(mic),
        ])]
        plan = MenuRoute.plan(facetime, microphone: mic, assistantDevices: assistant, preferredOutput: nil)
        check(plan.inputPress == MenuChoice(path: [0, 2], title: mic))
        check(plan.outputCurrent == nil && plan.outputPress == nil)

        // WhatsApp "Call": devices live in titled submenus.
        let whatsapp = [MenuNode(title: "Call", children: [
            item("Mute"),
            MenuNode(title: "Microphone", children: [item("MacBook Air Microphone", checked: true), item(mic)]),
            MenuNode(title: "Speaker", children: [item("Asistan Ses Çıkışı", checked: true), item("MacBook Air Speakers")]),
        ])]
        plan = MenuRoute.plan(whatsapp, microphone: mic, assistantDevices: assistant, preferredOutput: nil)
        check(plan.inputPress == MenuChoice(path: [0, 1, 1], title: mic))
        check(plan.outputPress == MenuChoice(path: [0, 2, 1], title: "MacBook Air Speakers"))

        // Real WhatsApp menus (from a diagnostics file) carry U+200E before each title.
        let lrm = "\u{200E}"
        let realWhatsApp = [MenuNode(title: lrm + "Call", children: [
            item(lrm + "End Call", enabled: false), item(""),
            MenuNode(title: lrm + "Camera", children: [item("FaceTime HD Camera", checked: true)]),
            MenuNode(title: lrm + "Microphone", children: [item(lrm + "Use system setting (Asistan Mikrofonu)", checked: true), item("MacBook Air Microphone"), item(mic)]),
            MenuNode(title: lrm + "Speaker", children: [item(lrm + "Use system setting (MacBook Air Speakers)"), item("MacBook Air Speakers", checked: true), item("Asistan Ses Çıkışı")]),
        ])]
        plan = MenuRoute.plan(realWhatsApp, microphone: mic, assistantDevices: assistant, preferredOutput: nil)
        check(plan.inputListed && plan.outputCurrent == "MacBook Air Speakers" && plan.outputPress == nil)
        check(plan.inputReady && plan.inputPress == nil)
        var notReady = realWhatsApp
        notReady[0].children[3].children[0].checked = false; notReady[0].children[3].children[1].checked = true
        notReady[0].children[3].children[0].title = lrm + "Use system setting (MacBook Air Microphone)"
        plan = MenuRoute.plan(notReady, microphone: mic, assistantDevices: assistant, preferredOutput: nil)
        check(plan.inputPress == MenuChoice(path: [0, 3, 2], title: mic))
        check(MenuRoute.section(of: lrm + "Microphone") == .input)

        // Without a heading the list could be either side: never press anything.
        let unlabelled = [MenuNode(title: "Audio", children: [item("MacBook Air Microphone", checked: true), item(mic)])]
        plan = MenuRoute.plan(unlabelled, microphone: mic, assistantDevices: assistant, preferredOutput: nil)
        check(!plan.inputListed && plan.inputPress == nil && plan.outputPress == nil)

        // Decomposed Turkish text and heading punctuation still match.
        check(MenuRoute.section(of: "Giris\u{0327}:") == .input)
        check(MenuRoute.section(of: "Hoparlör") == .output)
        check(MenuRoute.matches("Asistan Mikrofonu (Loopback)", mic))
        check(!MenuRoute.matches("Asistan Ses Çıkışı", mic))
        check(MenuRoute.isSystemSetting("Sistem Ayarını Kullan"))
        print("Menü ses seçimi: \(count) kontrol başarılı.")
    }
}

import Foundation

@main struct AnswerModeTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool) { precondition(condition); count += 1 }
        check(AnswerMode.current(paused: true, auto: true, focus: true) == .off)
        check(AnswerMode.current(paused: false, auto: false, focus: false) == .ask)
        check(AnswerMode.current(paused: false, auto: false, focus: true) == .focus)
        check(AnswerMode.current(paused: false, auto: true, focus: true) == .always)
        for mode in AnswerMode.allCases {
            let f = mode.flags(auto: true, focus: true)
            check(AnswerMode.current(paused: f.paused, auto: f.auto, focus: f.focus) == mode)
        }
        // Pausing keeps the automatic choice; resuming from a phone restores it.
        let paused = AnswerMode.off.flags(auto: false, focus: true)
        check(paused.paused && !paused.auto && paused.focus)
        check(AnswerMode.current(paused: false, auto: paused.auto, focus: paused.focus) == .focus)
        check(Set(AnswerMode.allCases.map(\.title)).count == 4)
        print("Cevaplama modu: \(count) kontrol başarılı.")
    }
}

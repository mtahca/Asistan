import Foundation

/// One choice for incoming calls, stored in the three existing preferences so a phone's
/// pause command and older settings keep working. "Off" keeps the automatic choices for later.
enum AnswerMode: String, CaseIterable {
    case off, ask, focus, always
    var title: String {
        switch self {
        case .off: return "Kapalı (duraklat)"
        case .ask: return "Bana sor"
        case .focus: return "Odak açıkken otomatik cevapla"
        case .always: return "Her zaman otomatik cevapla"
        }
    }
    static func current(paused: Bool, auto: Bool, focus: Bool) -> AnswerMode {
        paused ? .off : (auto ? .always : (focus ? .focus : .ask))
    }
    func flags(auto: Bool, focus: Bool) -> (paused: Bool, auto: Bool, focus: Bool) {
        switch self {
        case .off: return (true, auto, focus)
        case .ask: return (false, false, false)
        case .focus: return (false, false, true)
        case .always: return (false, true, false)
        }
    }
}

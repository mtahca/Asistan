import Foundation

/// A call app's menu as plain values, so the device decision can be tested without Accessibility.
struct MenuNode {
    var title: String
    var enabled = true
    var checked = false
    var children: [MenuNode] = []
}

struct MenuChoice: Equatable {
    var path: [Int]
    var title: String
}

struct MenuRoutePlan: Equatable {
    var inputListed = false
    var inputCurrent: String?
    var inputReady = false
    var inputPress: MenuChoice?
    var outputCurrent: String?
    var outputPress: MenuChoice?
}

enum MenuSection { case input, output, other }

/// Finds the microphone and speaker lists in a call app's menus and decides what to press.
/// Lists are recognised by a heading item (FaceTime "Video", Phone "Audio": "Microphone", "Output")
/// or by a submenu title (WhatsApp "Call" → "Microphone"). Unlabelled lists are never touched,
/// because Loopback devices can appear as both microphone and speaker.
enum MenuRoute {
    static let inputHeadings = ["microphone", "mikrofon", "input", "giriş", "ses girişi"]
    static let outputHeadings = ["output", "çıkış", "speaker", "speakers", "hoparlör", "ses çıkışı"]

    /// WhatsApp prefixes its menu titles with invisible direction marks (U+200E); drop them.
    static func normalized(_ text: String) -> String {
        let visible = text.unicodeScalars.filter { !(0x200E...0x200F).contains($0.value) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
        return String(String.UnicodeScalarView(visible)).precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func matches(_ title: String, _ device: String) -> Bool {
        let device = normalized(device)
        return !device.isEmpty && normalized(title).contains(device)
    }
    static func section(of title: String) -> MenuSection? {
        let text = normalized(title).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if inputHeadings.contains(text) { return .input }
        if outputHeadings.contains(text) { return .output }
        return nil
    }
    static func isSystemSetting(_ title: String) -> Bool {
        let text = normalized(title)
        return ["system setting", "system default", "sistem ayar", "sistem varsayılan"].contains { text.contains($0) }
    }

    struct Entry { var path: [Int]; var title: String; var checked: Bool; var section: MenuSection }

    static func entries(_ nodes: [MenuNode], path: [Int] = [], inherited: MenuSection = .other) -> [Entry] {
        var result: [Entry] = []
        var current = inherited
        for (index, node) in nodes.enumerated() {
            let here = path + [index]
            if !node.children.isEmpty {
                result += entries(node.children, path: here, inherited: section(of: node.title) ?? inherited)
                continue
            }
            if node.title.isEmpty { current = inherited; continue }          // separator
            if let heading = section(of: node.title) { current = heading; continue }
            if !node.enabled { current = .other; continue }                  // another heading (Camera…)
            result.append(Entry(path: here, title: node.title, checked: node.checked, section: current))
        }
        return result
    }

    static func plan(_ menus: [MenuNode], microphone: String, assistantDevices: [String], preferredOutput: String?) -> MenuRoutePlan {
        let all = entries(menus)
        let inputs = all.filter { $0.section == .input }, outputs = all.filter { $0.section == .output }
        var plan = MenuRoutePlan()
        plan.inputListed = !inputs.isEmpty
        plan.inputCurrent = inputs.first(where: { $0.checked })?.title
        plan.inputReady = plan.inputCurrent.map { matches($0, microphone) } ?? false
        // Prefer the device itself over "Use system setting (Asistan Mikrofonu)".
        let direct = inputs.first(where: { matches($0.title, microphone) && !isSystemSetting($0.title) })
        if !plan.inputReady, let target = direct ?? inputs.first(where: { matches($0.title, microphone) }) {
            plan.inputPress = MenuChoice(path: target.path, title: target.title)
        }
        let current = outputs.first(where: { $0.checked })
        plan.outputCurrent = current?.title
        if let current = current, assistantDevices.contains(where: { matches(current.title, $0) }) {
            let physical = outputs.filter { entry in !assistantDevices.contains(where: { matches(entry.title, $0) }) }
            let preferred = physical.first { entry in preferredOutput.map { matches(entry.title, $0) } ?? false }
            if let pick = preferred ?? physical.first(where: { isSystemSetting($0.title) }) ?? physical.first {
                plan.outputPress = MenuChoice(path: pick.path, title: pick.title)
            }
        }
        return plan
    }
}

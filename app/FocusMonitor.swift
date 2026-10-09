import Foundation

// Same local Focus store inspected by Alpha, without modifying it. macOS does not
// guarantee this private file format; unreadable or unfamiliar data stays unknown.
enum FocusPolicy {
    static func focused(_ data: Data) -> Bool? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["data"] as? [[String: Any]] else { return nil }
        if entries.isEmpty { return false }
        var known = false
        for entry in entries {
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            known = true
            if !records.isEmpty { return true }
        }
        return known ? false : nil
    }
    static func shouldAnswer(manualAuto: Bool, focusAuto: Bool, focused: Bool?, paused: Bool) -> Bool {
        !paused && (manualAuto || (focusAuto && focused == true))
    }
}
final class FocusMonitor {
    private var checked = Date.distantPast
    private(set) var active: Bool?
    var status: String { active.map { $0 ? "Odak açık" : "Odak kapalı" } ?? "Odak durumu okunamıyor; otomatik cevap tetiklenmez" }
    func refresh(enabled: Bool, force: Bool = false) {
        guard enabled else { active = nil; checked = .distantPast; return }
        guard force || Date().timeIntervalSince(checked) >= 2 else { return }
        checked = Date()
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        active = (try? Data(contentsOf: file)).flatMap { FocusPolicy.focused($0) }
    }
}

import Foundation
@main struct AssistantPreferencesTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool) { precondition(condition); count += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("preferences.json")
        check(try AssistantPreferences.load(from: path) == AssistantPreferences())
        var prefs = AssistantPreferences()
        prefs.general = "Tek bir soru sor."
        prefs.today = "Toplantıdayım."; prefs.todayDate = AssistantPreferences.dateKey()
        prefs.greeting = "Merhaba, ben yapay zekâ asistanıyım."
        prefs.aliases = try AssistantPreferences.parseAliases("  AŞKIM = Ayşe Hanım\nAnne=Ayşe Hanım\n")
        check(prefs.aliases["aşkım"] == "Ayşe Hanım")
        try prefs.save(to: path)
        check(try AssistantPreferences.load(from: path) == prefs)
        check((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        for invalid in ["Aşkım=Ayşe\naşkım=Başka", "Eksik eşittir", "Ad=", "=Hitap", "Ad=Hitap=Yanlış"] {
            do { _ = try AssistantPreferences.parseAliases(invalid); preconditionFailure("Invalid aliases accepted") } catch { count += 1 }
        }
        let previous = try Data(contentsOf: path)
        var bad = prefs; bad.general = String(repeating: "x", count: 8001)
        do { try bad.save(to: path); preconditionFailure("Oversized instructions accepted") } catch { count += 1 }
        check(try Data(contentsOf: path) == previous)
        bad = prefs; bad.aliases = ["name\nother": "hitap"]
        do { _ = try bad.validated(); preconditionFailure("Multiline key accepted") } catch { count += 1 }
        try Data("{broken".utf8).write(to: path)
        do { _ = try AssistantPreferences.load(from: path); preconditionFailure("Broken file accepted") } catch { count += 1 }
        check(try Data(contentsOf: path) == Data("{broken".utf8))
        print("Kişiselleştirme: \(count) kontrol başarılı.")
    }
}

import Foundation
@main struct MigrationNotesTests {
    static var count = 0
    static func check(_ value: Bool, line: Int = #line) {
        count += 1
        if !value { print("Geçiş ve son notlar: satır \(line) başarısız."); exit(1) }
    }
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("asistan-migration-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let legacy = AppMigration.legacyDataDirectory(home: home), current = AppMigration.dataDirectory(home: home)

        // No Beta data: the new folder is used and nothing is created early.
        check(AppMigration.resolveDataDirectory(home: home, legacyRunning: false).path == current.path)
        check(!fm.fileExists(atPath: current.path))

        // Beta still running: keep its folder in place.
        try fm.createDirectory(at: legacy.appendingPathComponent("notlar"), withIntermediateDirectories: true)
        try "ANTHROPIC_API_KEY=x\n".write(to: legacy.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        check(AppMigration.resolveDataDirectory(home: home, legacyRunning: true).path == legacy.path)
        check(fm.fileExists(atPath: legacy.path))

        // Beta closed: its folder moves with its contents.
        check(AppMigration.resolveDataDirectory(home: home, legacyRunning: false).path == current.path)
        check(!fm.fileExists(atPath: legacy.path))
        check(fm.fileExists(atPath: current.appendingPathComponent(".env").path))
        check(fm.fileExists(atPath: current.appendingPathComponent("notlar").path))

        // Both exist: the new folder wins and Beta's is left untouched.
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        check(AppMigration.resolveDataDirectory(home: home, legacyRunning: false).path == current.path)
        check(fm.fileExists(atPath: legacy.path))

        let suite = "asistan-migration-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "autoMode") // Alpha's value under the shared identifier
        AppMigration.migratePreferences(legacy: ["betaMobileCode": "12345678", "betaMobileEnabled": true, "paused": false], into: defaults)
        check(defaults.string(forKey: "betaMobileCode") == "12345678")
        check(defaults.bool(forKey: "betaMobileEnabled"))
        check(defaults.object(forKey: "autoMode") == nil)
        check(defaults.bool(forKey: AppMigration.migratedKey))
        AppMigration.migratePreferences(legacy: ["betaMobileCode": "87654321"], into: defaults)
        check(defaults.string(forKey: "betaMobileCode") == "12345678")

        let fresh = UserDefaults(suiteName: suite + "-fresh")!
        defer { fresh.removePersistentDomain(forName: suite + "-fresh") }
        fresh.set(true, forKey: "autoMode")
        AppMigration.migratePreferences(legacy: nil, into: fresh)
        check(fresh.bool(forKey: "autoMode"))

        check(RecentNotes.title(fileName: "2026-10-09_14-05-33_ab12cd34.md", header: "# Asistan — 09.10.2026 14:05\n\nArayan ekranı: Ayşe +90 555\n") == "09.10 14:05 · Ayşe +90 555")
        check(RecentNotes.title(fileName: "2026-10-09_14-05-33_ab12cd34.md", header: "Arayan ekranı: belirtilmedi\n") == "09.10 14:05 · Bilinmiyor")
        check(RecentNotes.title(fileName: "eski.md", header: "") == "eski.md · Bilinmiyor")
        let notes = current.appendingPathComponent("notlar")
        for (name, caller) in [("2026-10-08_09-00-00_a.md", "Ali"), ("2026-10-09_10-30-00_b.md", "Ayşe"), ("2026-10-07_08-00-00_c.md", "Can")] {
            try ("# Asistan\n\nArayan ekranı: " + caller + "\n").write(to: notes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "x".write(to: notes.appendingPathComponent("not.txt"), atomically: true, encoding: .utf8)
        let recent = RecentNotes.list(in: notes, limit: 2)
        check(recent.map(\.title) == ["09.10 10:30 · Ayşe", "08.10 09:00 · Ali"])
        check(RecentNotes.list(in: home.appendingPathComponent("yok")).isEmpty)
        print("Geçiş ve son notlar: \(count) kontrol başarılı.")
    }
}

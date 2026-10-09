import Foundation

/// 0.8 replaces both Alpha and Beta with one app. Beta's data folder and preferences
/// carry over once; nothing is deleted, and a failed move keeps using Beta's folder.
enum AppMigration {
    static let legacyBundleID = "com.mtahca.asistan.beta"
    static let migratedKey = "migratedFromBeta"
    /// Beta's preferences. Alpha shared some names (autoMode, paused) under this bundle
    /// identifier, so Beta's stored value — or its absence — decides the new value.
    static let preferenceKeys = ["autoMode", "paused", "showLive", "betaFocusAuto", "betaMobileEnabled",
                                 "betaMobileCode", "humanMicrophoneUID"]

    // isDirectory keeps the URL identical whether or not the folder exists yet.
    static func dataDirectory(home: URL) -> URL { home.appendingPathComponent("Documents/Asistan Data", isDirectory: true) }
    static func legacyDataDirectory(home: URL) -> URL { home.appendingPathComponent("Documents/Codex/Asistan Beta Data", isDirectory: true) }

    /// Returns the folder to use. Beta's folder moves only when it exists, the new one does not,
    /// and Beta is not running (its agent may be writing there).
    static func resolveDataDirectory(home: URL, legacyRunning: Bool, fileManager: FileManager = .default) -> URL {
        let current = dataDirectory(home: home), legacy = legacyDataDirectory(home: home)
        guard !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) else { return current }
        if legacyRunning { return legacy }
        do {
            try fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: current)
            return current
        } catch { return legacy }
    }

    /// Copies Beta's preferences once. Without a Beta domain, existing values stay as they are.
    static func migratePreferences(legacy: [String: Any]?, into defaults: UserDefaults) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        guard let legacy = legacy, !legacy.isEmpty else { return }
        for key in preferenceKeys {
            if let value = legacy[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
}

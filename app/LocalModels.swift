import Foundation

struct LocalModelEntry: Equatable {
    let repo: String
    let bytes: Int64
    let revision: String
    let updated: Date?
}

/// Reads which local speech models are on disk (Hugging Face cache and the Python package) without starting Python.
enum LocalModels {
    static let package = "ema_lightning"

    static func hubDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let cache = environment["HF_HUB_CACHE"], !cache.isEmpty { return URL(fileURLWithPath: cache) }
        let base = environment["HF_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".cache/huggingface")
        return base.appendingPathComponent("hub")
    }

    static func installed(hub: URL) -> [LocalModelEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: hub.path) else { return [] }
        return names.filter { $0.hasPrefix("models--") }.sorted().map { name in
            let folder = hub.appendingPathComponent(name)
            let repo = String(name.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
            let blobs = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("blobs").path)) ?? []
            let bytes = blobs.reduce(Int64(0)) { total, file in
                let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("blobs/" + file).path)
                return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            let ref = folder.appendingPathComponent("refs/main")
            let revision = (try? String(contentsOf: ref, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let updated = (try? fm.attributesOfItem(atPath: ref.path))?[.modificationDate] as? Date
            return LocalModelEntry(repo: repo, bytes: bytes, revision: revision, updated: updated)
        }.filter { $0.bytes > 0 }
    }

    /// Version of the `ema-lightning` Python package in the app's own environment, nil when it is not installed.
    static func packageVersion(venv: URL) -> String? {
        let fm = FileManager.default
        let lib = venv.appendingPathComponent("lib")
        for python in ((try? fm.contentsOfDirectory(atPath: lib.path)) ?? []).sorted() where python.hasPrefix("python") {
            let site = lib.appendingPathComponent(python + "/site-packages")
            for item in (try? fm.contentsOfDirectory(atPath: site.path)) ?? [] where item.hasPrefix(package + "-") && item.hasSuffix(".dist-info") {
                return String(item.dropFirst(package.count + 1).dropLast(".dist-info".count))
            }
        }
        return nil
    }

    static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func describe(_ entries: [LocalModelEntry], packageVersion: String?) -> String {
        var lines = [packageVersion.map { "✓ ema-lightning (Türkçe ses) · paket \($0)" } ?? "○ ema-lightning paketi kurulu değil"]
        if entries.isEmpty { lines.append("○ İndirilmiş yerel model yok") }
        let dates = DateFormatter(); dates.locale = Locale(identifier: "tr_TR"); dates.dateStyle = .medium; dates.timeStyle = .none
        for entry in entries {
            let short = String(entry.revision.prefix(8))
            lines.append("✓ " + entry.repo + " · " + sizeText(entry.bytes) + (entry.updated.map { " · " + dates.string(from: $0) } ?? "") + (short.isEmpty ? "" : " · sürüm " + short))
        }
        return lines.joined(separator: "\n")
    }

    /// Result of `local_models.py check`: what has a newer version available.
    static func updateSummary(_ json: [String: Any]) -> (available: Bool, text: String) {
        var lines: [String] = []
        if let package = json["package"] as? [String: Any], (package["update"] as? Bool) == true {
            lines.append("• ema-lightning \(package["installed"] as? String ?? "?") → \(package["latest"] as? String ?? "?")")
        }
        for model in (json["models"] as? [[String: Any]]) ?? [] where (model["update"] as? Bool) == true {
            lines.append("• " + (model["repo"] as? String ?? "Model") + ": yeni sürüm " + String((model["remote"] as? String ?? "").prefix(8)))
        }
        let errors = (json["errors"] as? [String]) ?? []
        if !lines.isEmpty { return (true, "Güncelleme var:\n" + lines.joined(separator: "\n")) }
        if !errors.isEmpty { return (false, "Denetlenemedi: " + errors.joined(separator: "; ")) }
        return (false, "Yerel modeller ve paket güncel.")
    }
}

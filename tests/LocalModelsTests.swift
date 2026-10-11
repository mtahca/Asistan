import Foundation

@main
struct LocalModelsTests {
    static func main() throws {
        var count = 0
        func check(_ result: Bool, _ line: Int = #line) { precondition(result, "LocalModelsTests satır \(line)"); count += 1 }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("asistan-local-models-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let hub = root.appendingPathComponent("hub")
        let blobs = hub.appendingPathComponent("models--org--ses-modeli/blobs")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(count: 3000).write(to: blobs.appendingPathComponent("a"))
        try Data(count: 2000).write(to: blobs.appendingPathComponent("b"))
        try fm.createDirectory(at: hub.appendingPathComponent("models--org--ses-modeli/refs"), withIntermediateDirectories: true)
        try "0123456789abcdef\n".write(to: hub.appendingPathComponent("models--org--ses-modeli/refs/main"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: hub.appendingPathComponent("models--bos--model/blobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: hub.appendingPathComponent("datasets--x--y/blobs"), withIntermediateDirectories: true)

        // Shared-store layout: the model's blobs are links into hub/blobs; two links to one file count once.
        let shared = hub.appendingPathComponent("blobs/ab")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data(count: 7000).write(to: shared.appendingPathComponent("hash1"))
        let linked = hub.appendingPathComponent("models--org--bagli-model/blobs")
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linked.appendingPathComponent("x").path, withDestinationPath: "../../blobs/ab/hash1")
        try fm.createSymbolicLink(atPath: linked.appendingPathComponent("y").path, withDestinationPath: "../../blobs/ab/hash1")

        let entries = LocalModels.installed(hub: hub)
        check(entries.count == 2)
        let plain = entries.first { $0.repo == "org/ses-modeli" }!
        check(plain.bytes == 5000 && plain.revision == "0123456789abcdef")
        check(entries.first { $0.repo == "org/bagli-model" }?.bytes == 7000)
        check(LocalModels.installed(hub: root.appendingPathComponent("yok")).isEmpty)

        check(LocalModels.hubDirectory(environment: ["HF_HUB_CACHE": "/x/hub"], home: root).path == "/x/hub")
        check(LocalModels.hubDirectory(environment: ["HF_HOME": "/x/hf"], home: root).path == "/x/hf/hub")
        check(LocalModels.hubDirectory(environment: [:], home: root).path == root.path + "/.cache/huggingface/hub")

        let venv = root.appendingPathComponent(".venv")
        check(LocalModels.packageVersion(venv: venv) == nil)
        try fm.createDirectory(at: venv.appendingPathComponent("lib/python3.12/site-packages/ema_lightning-1.0.1.dist-info"), withIntermediateDirectories: true)
        try fm.createDirectory(at: venv.appendingPathComponent("lib/python3.12/site-packages/ema_lightning"), withIntermediateDirectories: true)
        check(LocalModels.packageVersion(venv: venv) == "1.0.1")

        let text = LocalModels.describe([plain], packageVersion: "1.0.1")
        check(text.contains("org/ses-modeli") && text.contains("sürüm 01234567") && text.contains("paket 1.0.1"))
        check(LocalModels.describe([], packageVersion: nil).contains("kurulu değil"))

        let none = LocalModels.updateSummary(["package": ["update": false], "models": [], "errors": []])
        check(!none.available && none.text.contains("güncel"))
        let some = LocalModels.updateSummary(["package": ["update": true, "installed": "1.0.1", "latest": "1.1.0"], "models": [["repo": "org/ses-modeli", "update": true, "remote": "fedcba9876543210"]], "errors": []])
        check(some.available && some.text.contains("1.0.1 → 1.1.0") && some.text.contains("fedcba98"))
        let failed = LocalModels.updateSummary(["package": ["update": false], "models": [], "errors": ["ağ yok"]])
        check(!failed.available && failed.text.contains("ağ yok"))
        print("Yerel modeller: \(count) kontrol başarılı.")
    }
}

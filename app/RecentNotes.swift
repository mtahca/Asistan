import Foundation

/// Recent call notes for the menu: newest first, titled from the file name and caller line.
struct RecentNote: Equatable {
    let url: URL
    let title: String
}

enum RecentNotes {
    static func list(in folder: URL, limit: Int = 8, fileManager: FileManager = .default) -> [RecentNote] {
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { RecentNote(url: $0, title: title(fileName: $0.lastPathComponent, header: header(of: $0))) }
    }

    /// A note path from the agent must be a .md file directly inside the notes folder. Paths are
    /// compared, not URLs: a folder URL ends in "/" only when it existed at creation time.
    static func isNote(path: String, in folder: URL) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.pathExtension == "md" && url.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    /// The caller line sits near the top; notes may be long, so read only the beginning.
    static func header(of url: URL, bytes: Int = 2048) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }

    /// The text under "## Özet", up to the next heading.
    static func summary(from text: String) -> String {
        guard let start = text.range(of: "## Özet\n") else { return "" }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recent calls for Asistan Mobile: titles and summaries only, never the full transcript.
    static func historyItems(in folder: URL, limit: Int = 20) -> [[String: Any]] {
        list(in: folder, limit: limit).map { note in
            let text = header(of: note.url, bytes: 32768)
            let modified = (try? note.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return ["id": note.url.lastPathComponent, "title": note.title, "ts": modified.timeIntervalSince1970,
                    "summary": String(summary(from: text).prefix(1200))]
        }
    }

    /// "2026-10-09_14-05-33_ab12cd34.md" + "Arayan ekranı: Ayşe" -> "09.10 14:05 · Ayşe"
    static func title(fileName: String, header: String) -> String {
        let parts = fileName.split(separator: "_")
        var when = fileName
        if parts.count >= 2 {
            let date = parts[0].split(separator: "-"), time = parts[1].split(separator: "-")
            if date.count == 3, time.count >= 2 { when = "\(date[2]).\(date[1]) \(time[0]):\(time[1])" }
        }
        let prefix = "Arayan ekranı: "
        let caller = header.split(separator: "\n").first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) } ?? ""
        let shown = caller.isEmpty || caller == "belirtilmedi" ? "Bilinmiyor" : String(caller.prefix(40))
        return when + " · " + shown
    }
}

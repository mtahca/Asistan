import Foundation

/// Decode only complete UTF-8 lines; a pipe may split a Turkish character anywhere.
final class AgentLineDecoder {
    private var buffer = Data()
    func reset() { buffer.removeAll(keepingCapacity: true) }
    func append(_ bytes: Data) -> [String] {
        buffer.append(bytes)
        var lines: [String] = []
        while let index = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<index])
            buffer.removeSubrange(...index)
            if let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
        if buffer.count > 1_048_576 { buffer.removeAll() }
        return lines
    }
    static func event(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("@beta "), let data = String(line.dropFirst(6)).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["event"] is String else { return nil }
        return object
    }
}

// Wire-compatible with Asistan Mobile v1. Bonjour endpoints carry Beta's own port.
import Foundation
import Network
import Security
import CryptoKit

enum LiveProtocol {
    static let serviceType = "_asistan-canli._tcp"
    static let port: UInt16 = 47822 // Alpha keeps 47821. Mobile uses the discovered endpoint.
    static let version = 1
    static func serviceName(host: String) -> String {
        let suffix = " — Asistan Beta"
        var base = host.isEmpty ? "Mac" : host
        while (base + suffix).utf8.count > 63 { base.removeLast() }
        return base + suffix
    }
    static func tlsOptions(code: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(code.utf8))
        let psk = Data(HMAC<SHA256>.authenticationCode(for: Data("asistan-canli-v1".utf8), using: key))
        let identity = Data("asistan-canli".utf8)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        return tls
    }
    static func parameters(code: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        let p = NWParameters(tls: tlsOptions(code: code), tcp: tcp)
        p.includePeerToPeer = true
        return p
    }
    static func encode(_ obj: [String: Any]) -> Data? {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        d.append(0x0A); return d
    }
}

enum MobileCommand: Equatable {
    case ping, answer, end, note(String)
    static func parse(_ obj: [String: Any]) -> MobileCommand? {
        switch obj["t"] as? String {
        case "ping": return .ping
        case "answer": return .answer
        case "end": return .end
        case "note":
            guard let raw = obj["text"] as? String else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.unicodeScalars.count <= 1000 else { return nil }
            return .note(text)
        default: return nil // no arbitrary execution or outgoing calls
        }
    }
    func allowed(ringing: Bool, inSession: Bool, paused: Bool, stopping: Bool) -> Bool {
        switch self {
        case .ping: return true
        case .answer: return ringing && !inSession && !paused && !stopping
        case .note, .end: return inSession && !stopping
        }
    }
}

struct MobileFrames {
    static let limit = 16384
    private var buffer = Data()
    mutating func consume(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var result: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard line.count <= Self.limit,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw InvalidFrame() }
            result.append(obj)
        }
        guard buffer.count <= Self.limit else { throw InvalidFrame() }
        return result
    }
    struct InvalidFrame: Error {}
}

// Rolling, bounded live transcript. Snapshots replace partial GPT-Live rows instead of duplicating them.
struct MobileTranscript {
    private(set) var lines: [[String: Any]] = []
    private var sequence = 0
    mutating func reset() { lines.removeAll() }
    mutating func append(kind: String, speaker: String, text: String) -> [String: Any] {
        sequence += 1
        let row: [String: Any] = ["id": sequence, "kind": kind, "speaker": String(speaker.prefix(80)), "text": String(text.prefix(2048)), "ts": Date().timeIntervalSince1970]
        lines.append(row); trim(); return row
    }
    mutating func replace(_ entries: [(String, String, String)]) {
        // Stable ids let the existing iOS client scroll when the last row changes.
        let old = lines
        lines = []
        for (index, entry) in entries.suffix(200).enumerated() {
            let (kind, speaker, text) = entry
            sequence += 1
            let clipped = String(text.prefix(2048))
            var row: [String: Any] = ["id": sequence, "kind": kind, "speaker": String(speaker.prefix(80)), "text": clipped, "ts": Date().timeIntervalSince1970]
            if index < old.count, old[index]["kind"] as? String == kind, old[index]["speaker"] as? String == speaker,
               old[index]["text"] as? String == clipped {
                row["id"] = old[index]["id"]; row["ts"] = old[index]["ts"]
            }
            lines.append(row)
        }
        trim()
    }

    private mutating func trim() {
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        while !lines.isEmpty, (LiveProtocol.encode(["t": "snapshot", "lines": lines])?.count ?? Int.max) > 262144 { lines.removeFirst() }
    }
}

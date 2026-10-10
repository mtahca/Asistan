// Shared by Asistan (app/MobileProtocol.swift) and Asistan Mobile (AsistanCanli/MobileProtocol.swift).
// Both copies must stay byte-identical; CI in each repository compares them.
// v1: 8-digit pairing code on port 47821. v2: random 256-bit key from a QR code on port 47822.
// An 8-digit code can be guessed offline from one recorded handshake; a 256-bit key cannot.
import Foundation
import Network
import Security
import CryptoKit

enum LiveProtocol {
    static let serviceType = "_asistan-canli._tcp"
    static let port: UInt16 = 47821
    static let version = 1
    static let secureServiceType = "_asistan-v2._tcp"
    static let securePort: UInt16 = 47822
    /// Announced in hello; clients check features here instead of comparing version numbers.
    static let capabilities = ["pause", "quickNotes", "history", "secure"]
    static func serviceName(host: String) -> String {
        let suffix = " — Asistan"
        var base = host.isEmpty ? "Mac" : host
        while (base + suffix).utf8.count > 63 { base.removeLast() }
        return base + suffix
    }
    static func tlsOptions(code: String) -> NWProtocolTLS.Options {
        tlsOptions(psk: Data(HMAC<SHA256>.authenticationCode(for: Data("asistan-canli-v1".utf8), using: SymmetricKey(data: Data(code.utf8)))),
                   identity: "asistan-canli")
    }
    static func tlsOptions(key: Data) -> NWProtocolTLS.Options {
        tlsOptions(psk: Data(HMAC<SHA256>.authenticationCode(for: Data("asistan-canli-v2".utf8), using: SymmetricKey(data: key))),
                   identity: "asistan-v2")
    }
    private static func tlsOptions(psk: Data, identity: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        return tls
    }
    static func parameters(code: String) -> NWParameters { parameters(tls: tlsOptions(code: code)) }
    static func parameters(key: Data) -> NWParameters { parameters(tls: tlsOptions(key: key)) }
    private static func parameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }
    /// IPv4 addresses for Mobile's manual address field; loopback and link-local are skipped.
    static func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254."), !result.contains(text) { result.append(text) }
        }
        return result
    }
    static func encode(_ obj: [String: Any]) -> Data? {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        d.append(0x0A); return d
    }
}

/// QR payload: asistan://pair?k=<base64url key>&n=<Mac name>&h=<IPv4,IPv4>
struct PairingLink: Equatable {
    static let keyLength = 32
    let key: Data
    let mac: String
    let hosts: [String]
    init(key: Data, mac: String, hosts: [String]) { self.key = key; self.mac = mac; self.hosts = hosts }
    init?(_ text: String) {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "asistan", parts.host == "pair" else { return nil }
        func value(_ name: String) -> String { parts.queryItems?.first { $0.name == name }?.value ?? "" }
        guard let key = Self.decode(value("k")), key.count == Self.keyLength else { return nil }
        self.key = key
        mac = String(value("n").prefix(63))
        hosts = value("h").split(separator: ",").map(String.init).filter { !$0.isEmpty }.prefix(4).map { $0 }
    }
    var url: String {
        var parts = URLComponents()
        parts.scheme = "asistan"; parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "k", value: Self.encode(key)), URLQueryItem(name: "n", value: mac),
                            URLQueryItem(name: "h", value: hosts.joined(separator: ","))]
        return parts.string ?? ""
    }
    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

enum MobileCommand: Equatable {
    case ping, answer, end, note(String), pause(Bool)
    static func parse(_ obj: [String: Any]) -> MobileCommand? {
        switch obj["t"] as? String {
        case "ping": return .ping
        case "answer": return .answer
        case "end": return .end
        case "pause":
            guard let on = obj["on"] as? Bool else { return nil }
            return .pause(on)
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
        case .pause: return !inSession && !stopping  // a paired phone may pause answering any time
        }
    }
}

/// Newline-delimited JSON. The Mac accepts short commands; the phone accepts larger snapshots.
struct MobileFrames {
    static let limit = 16384
    let maxLine: Int
    private var buffer = Data()
    init(limit: Int = MobileFrames.limit) { maxLine = limit }
    mutating func consume(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var result: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard line.count <= maxLine,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw InvalidFrame() }
            result.append(obj)
        }
        guard buffer.count <= maxLine else { throw InvalidFrame() }
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

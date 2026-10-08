// Asistan — iPhone köprüsü
// Canlı metin penceresindeki satırları yerel ağdaki Asistan Canlı (iOS) uygulamasına yayınlar.
// Bağlantı Bonjour ile bulunur, TLS-PSK ile şifrelenir: anahtar, Mac'te gösterilen 8 haneli eşleştirme kodundan türetilir.
// Kodu bilmeyen cihaz TLS el sıkışmasını geçemez. Protokol: satır başına bir JSON nesnesi (\n ile ayrılır).
// Protokol sabitleri ve tlsOptions, Asistan-Mobile deposundaki AsistanCanli/LiveProtocol.swift ile aynı kalmalı.

import Cocoa
import Network
import Security
import CryptoKit

enum LiveProtocol {
    static let serviceType = "_asistan-canli._tcp"
    static let port: UInt16 = 47821
    static let version = 1

    /// Eşleştirme kodundan TLS-PSK seçenekleri (iki uçta da aynı kod -> aynı anahtar)
    static func tlsOptions(code: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(code.utf8))
        let psk = Data(HMAC<SHA256>.authenticationCode(for: Data("asistan-canli-v1".utf8), using: key))
        let identity = Data("asistan-canli".utf8)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                pskData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        return tls
    }

    static func parameters(code: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let p = NWParameters(tls: tlsOptions(code: code), tcp: tcp)
        p.includePeerToPeer = true
        return p
    }

    static func encode(_ obj: [String: Any]) -> Data? {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        d.append(0x0A)
        return d
    }
}

/// Tek bir iPhone bağlantısı
final class MobileClient {
    let conn: NWConnection
    var buffer = Data()
    var ready = false
    weak var bridge: MobileBridge?

    init(_ conn: NWConnection, bridge: MobileBridge) {
        self.conn = conn
        self.bridge = bridge
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                self.ready = true
                self.bridge?.clientReady(self)
                self.receive()
            case .failed(let e):
                logLine("iPhone bağlantısı koptu: \(e)")
                self.conn.cancel()
                self.bridge?.drop(self)
            case .cancelled:
                self.bridge?.drop(self)
            default: break
            }
        }
        conn.start(queue: .main)
    }

    func send(_ obj: [String: Any]) {
        guard ready, let d = LiveProtocol.encode(obj) else { return }
        conn.send(content: d, completion: .contentProcessed { _ in })
    }

    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > 1_000_000 { self.conn.cancel(); return }   // anlamsız büyük girdi
                while let nl = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                    self.buffer.removeSubrange(self.buffer.startIndex...nl)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        self.bridge?.handle(obj, from: self)
                    }
                }
            }
            if done || err != nil { self.conn.cancel(); return }
            self.receive()
        }
    }
}

/// Mac tarafı sunucu: canlı metni yayınlar, iPhone'dan gelen talimat / sonlandır komutlarını iletir.
/// Tüm işler ana kuyrukta çalışır.
final class MobileBridge {
    var onNote: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var onClientsChanged: (() -> Void)?

    private(set) var enabled = UserDefaults.standard.bool(forKey: "mobileBridge")
    private(set) var code: String
    private var listener: NWListener?
    private var clients: [MobileClient] = []
    private var lines: [[String: Any]] = []     // son görüşmenin satırları (yeni bağlanana gönderilir)
    private var seq = 0
    private var state: [String: Any] = ["t": "state", "inSession": false, "caller": "", "status": ""]

    private lazy var macName = Host.current().localizedName ?? "Mac"

    var clientCount: Int { clients.filter { $0.ready }.count }

    init() {
        if let c = UserDefaults.standard.string(forKey: "mobileBridgeCode"), c.count == 8 {
            code = c
        } else {
            code = MobileBridge.newCode()
            UserDefaults.standard.set(code, forKey: "mobileBridgeCode")
        }
        if enabled { startListener() }
    }

    static func newCode() -> String {
        String(format: "%08d", Int.random(in: 0..<100_000_000))
    }

    /// "1234 5678" biçiminde, gösterim için
    var displayCode: String { String(code.prefix(4)) + " " + String(code.suffix(4)) }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "mobileBridge")
        if on { startListener() } else { stopListener() }
    }

    func regenerateCode() {
        code = MobileBridge.newCode()
        UserDefaults.standard.set(code, forKey: "mobileBridgeCode")
        if enabled { stopListener(); startListener() }   // eski kodla bağlı cihazlar düşer
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: LiveProtocol.parameters(code: code),
                                   on: NWEndpoint.Port(rawValue: LiveProtocol.port)!)
            l.service = NWListener.Service(name: macName, type: LiveProtocol.serviceType)
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: logLine("iPhone köprüsü dinliyor (port \(LiveProtocol.port), Bonjour \(LiveProtocol.serviceType))")
                case .failed(let e):
                    logLine("iPhone köprüsü başlatılamadı: \(e)")
                    self?.listener?.cancel()
                    self?.listener = nil
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self = self else { conn.cancel(); return }
                if self.clients.count >= 8 { conn.cancel(); return }
                let c = MobileClient(conn, bridge: self)
                self.clients.append(c)
                c.start()
            }
            l.start(queue: .main)
            listener = l
        } catch {
            logLine("iPhone köprüsü başlatılamadı: \(error)")
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        for c in clients { c.conn.cancel() }
        clients.removeAll()
        onClientsChanged?()
    }

    fileprivate func clientReady(_ c: MobileClient) {
        logLine("iPhone bağlandı: \(c.conn.endpoint)")
        c.send(["t": "hello", "v": LiveProtocol.version, "mac": macName])
        c.send(state)
        c.send(["t": "snapshot", "lines": lines])
        onClientsChanged?()
    }

    fileprivate func drop(_ c: MobileClient) {
        let before = clients.count
        clients.removeAll { $0 === c }
        if clients.count != before { onClientsChanged?() }
    }

    fileprivate func handle(_ obj: [String: Any], from c: MobileClient) {
        switch obj["t"] as? String {
        case "note":
            if let text = obj["text"] as? String { onNote?(String(text.prefix(2000))) }
        case "end":
            onEnd?()
        case "ping":
            c.send(["t": "pong"])
        default: break
        }
    }

    private func broadcast(_ obj: [String: Any]) {
        guard enabled else { return }
        for c in clients { c.send(obj) }
    }

    // MARK: Canlı pencereden gelen olaylar

    /// Yeni görüşme: telefondaki metin de temizlenir
    func reset() {
        lines.removeAll()
        broadcast(["t": "reset"])
    }

    /// kind: caller | assistant | interrupted | you | note
    func append(kind: String, speaker: String, text: String) {
        seq += 1
        let line: [String: Any] = ["t": "line", "id": seq, "kind": kind, "speaker": speaker, "text": text,
                                   "ts": Date().timeIntervalSince1970]
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        broadcast(line)
    }

    /// Yalnızca değiştiğinde yayınlar (her tick'te çağrılabilir)
    func setState(inSession: Bool, caller: String, startedAt: Date?, status: String) {
        var s: [String: Any] = ["t": "state", "inSession": inSession, "caller": caller, "status": status]
        if let t = startedAt, inSession { s["startedAt"] = t.timeIntervalSince1970 }
        if NSDictionary(dictionary: s).isEqual(to: state) { return }
        state = s
        broadcast(s)
    }
}

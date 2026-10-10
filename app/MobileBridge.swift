import Foundation
import Network

final class MobileClient {
    let connection: NWConnection
    weak var bridge: MobileBridge?
    var ready = false
    var context: String?
    private var frames = MobileFrames()
    private var pending: [Data] = []
    private var queuedBytes = 0
    private var sending = false
    private var tokens = 5.0
    private var lastCommand = Date()
    private var handshakeTimer: DispatchWorkItem?
    init(_ connection: NWConnection, bridge: MobileBridge) { self.connection = connection; self.bridge = bridge }
    func start() {
        let timeout = DispatchWorkItem { [weak self] in if self?.ready == false { self?.close() } }
        handshakeTimer = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.handshakeTimer?.cancel(); self.ready = true
                self.bridge?.clientReady(self); self.receive()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func allowCommand() -> Bool {
        let now = Date(); tokens = min(5, tokens + max(0, now.timeIntervalSince(lastCommand))); lastCommand = now
        guard tokens >= 1 else { return false }; tokens -= 1; return true
    }
    func close() {
        handshakeTimer?.cancel(); ready = false; pending.removeAll(); queuedBytes = 0
        connection.stateUpdateHandler = nil; connection.cancel(); bridge?.drop(self)
    }
    func send(_ obj: [String: Any]) {
        guard ready, let data = LiveProtocol.encode(obj) else { return }
        guard queuedBytes + data.count <= 1048576, pending.count < 128 else { close(); return }
        queuedBytes += data.count; pending.append(data); flush()
    }
    private func flush() {
        guard ready, !sending, !pending.isEmpty else { return }
        sending = true; let data = pending.removeFirst()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self, self.ready else { return }
            self.queuedBytes -= data.count; self.sending = false
            if error != nil { self.close() } else { self.flush() }
        })
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self = self, self.ready else { return }
            if let data = data {
                do { for obj in try self.frames.consume(data) { self.bridge?.handle(obj, from: self) } }
                catch { self.close(); return }
            }
            if done || error != nil { self.close(); return }; self.receive()
        }
    }
}

// All callbacks run on the main queue. Disabled by default; keeps the pairing code carried over from Beta.
final class MobileBridge {
    var onNote: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var onAnswer: (() -> Void)?
    var onPause: ((Bool) -> Void)?
    var onChanged: (() -> Void)?
    private let defaults: UserDefaults
    private(set) var enabled: Bool
    private(set) var code: String
    private(set) var key: Data
    /// Old Asistan Mobile versions only know the 8-digit code; turn this off once every phone uses the QR code.
    private(set) var legacyEnabled: Bool
    private(set) var listening = false
    private(set) var failure: String?
    private var listener: NWListener?
    private var secureListener: NWListener?
    private var quickNotes: [String] = []
    private var history: [[String: Any]] = []
    private var clients: [MobileClient] = []
    private var transcript = MobileTranscript()
    private var state: [String: Any] = ["t": "state", "inSession": false, "caller": "", "status": "", "ringing": false, "ringer": "", "source": "", "paused": false, "humanCall": false]
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private var context: String?
    private var paused = false
    private var stopping = false
    private var noticeSequence = -1
    let macName: String
    var clientCount: Int { clients.filter { $0.ready }.count }
    var displayCode: String { String(code.prefix(4)) + " " + String(code.suffix(4)) }
    var status: String {
        if !enabled { return "Mobil bağlantı kapalı" }
        if let failure = failure { return failure }
        return listening ? "Mobil bağlantı açık · \(clientCount) cihaz bağlı" : "Mobil bağlantı başlatılıyor…"
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "betaMobileEnabled")
        macName = LiveProtocol.serviceName(host: Host.current().localizedName ?? "Mac")
        if let stored = defaults.string(forKey: "betaMobileCode"), stored.utf8.count == 8, stored.utf8.allSatisfy({ (48...57).contains($0) }) { code = stored }
        else { code = Self.newCode(); defaults.set(code, forKey: "betaMobileCode") }
        if let stored = defaults.string(forKey: "mobileKey").flatMap(PairingLink.decode), stored.count == PairingLink.keyLength { key = stored }
        else { key = PairingLink.newKey(); defaults.set(PairingLink.encode(key), forKey: "mobileKey") }
        legacyEnabled = (defaults.object(forKey: "mobileLegacyCode") as? Bool) ?? true
    }
    static func newCode() -> String { String(format: "%08d", Int.random(in: 0..<100_000_000)) }
    func startIfEnabled() { if enabled { startListener() } }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "betaMobileEnabled")
        if value { startListener() } else { stopListener() }; onChanged?()
    }
    /// Renews both the QR key and the 8-digit code; every paired phone must pair again.
    func regenerateCode() {
        let old = code
        repeat { code = Self.newCode() } while code == old
        defaults.set(code, forKey: "betaMobileCode")
        key = PairingLink.newKey(); defaults.set(PairingLink.encode(key), forKey: "mobileKey")
        stopListener(); if enabled { startListener() }; onChanged?()
    }
    func setLegacyEnabled(_ value: Bool) {
        legacyEnabled = value; defaults.set(value, forKey: "mobileLegacyCode")
        stopListener(); if enabled { startListener() }; onChanged?()
    }
    func shutdown() { stopListener() }
    private func startListener() {
        guard listener == nil, secureListener == nil else { return }; failure = nil; listening = false
        do {
            secureListener = try makeListener(LiveProtocol.parameters(key: key), port: LiveProtocol.securePort, type: LiveProtocol.secureServiceType)
            if legacyEnabled { listener = try makeListener(LiveProtocol.parameters(code: code), port: LiveProtocol.port, type: LiveProtocol.serviceType) }
        } catch {
            stopListener()
            failure = "Mobil bağlantı başlatılamadı. Yerel ağ iznini ve \(LiveProtocol.port)–\(LiveProtocol.securePort) portlarını kontrol edin."; onChanged?()
        }
    }
    private func makeListener(_ parameters: NWParameters, port: UInt16, type: String) throws -> NWListener {
        let l = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        l.service = NWListener.Service(name: macName, type: type)
        l.stateUpdateHandler = { [weak self, weak l] status in
            guard let self = self, let l = l, self.listener === l || self.secureListener === l else { return }
            switch status {
            case .ready:
                let all = [self.listener, self.secureListener].compactMap { $0 }
                self.listening = all.allSatisfy { if case .ready = $0.state { return true }; return false }; self.failure = nil
                logLine("Mobil bağlantı hazır; port \(port)"); self.restartDelay = 2
            case .waiting(let error), .failed(let error):
                // A network change or sleep can stop a listener; log it and restart instead of going silent.
                logLine("Mobil bağlantı durdu; port \(port): \(error)")
                self.stopListener(); self.failure = "Mobil bağlantı yeniden başlatılıyor…"
                self.scheduleRestart()
            default: break
            }; self.onChanged?()
        }
        l.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.enabled, self.clients.count < 4 else { connection.cancel(); return }
            let client = MobileClient(connection, bridge: self); self.clients.append(client); client.start()
        }
        l.start(queue: .main)
        return l
    }
    private var restartDelay: TimeInterval = 2
    private var restartWork: DispatchWorkItem?
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.enabled, self.listener == nil, self.secureListener == nil else { return }
            self.startListener(); self.onChanged?()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: work)
        restartDelay = min(restartDelay * 2, 60)
    }
    private func stopListener() {
        restartWork?.cancel(); restartWork = nil
        for l in [listener, secureListener].compactMap({ $0 }) { l.stateUpdateHandler = nil; l.newConnectionHandler = nil; l.cancel() }
        listener = nil; secureListener = nil; listening = false
        let old = clients; clients.removeAll(); for client in old { client.close() }; onChanged?()
    }
    fileprivate func clientReady(_ client: MobileClient) {
        guard enabled, clients.contains(where: { $0 === client }) else { client.close(); return }
        client.context = context
        client.send(["t": "hello", "v": LiveProtocol.version, "mac": macName, "app": appVersion, "caps": LiveProtocol.capabilities])
        client.send(state); client.send(["t": "snapshot", "lines": transcript.lines])
        client.send(["t": "quickNotes", "items": quickNotes]); client.send(["t": "history", "items": history, "fresh": false]); onChanged?()
    }
    fileprivate func drop(_ client: MobileClient) {
        let before = clients.count; clients.removeAll { $0 === client }
        if before != clients.count { onChanged?() }
    }
    fileprivate func handle(_ obj: [String: Any], from client: MobileClient) {
        guard enabled, client.ready else { return }
        guard let command = MobileCommand.parse(obj) else {
            if obj["t"] as? String == "note", client.allowCommand() { notice("Not gönderilemedi: metin boş olmamalı ve en fazla 1000 karakter olabilir.", to: client) }
            return
        }
        if command == .ping { client.send(["t": "pong"]); return }
        // Pausing needs no call context: it is allowed with no call at all.
        if case .pause(let on) = command {
            guard client.allowCommand(), command.allowed(ringing: false, inSession: state["inSession"] as? Bool ?? false, paused: paused, stopping: stopping) else {
                notice("Duraklatma görüşme sırasında değiştirilemez.", to: client); return
            }
            onPause?(on); return
        }
        guard client.allowCommand(), client.context == context, context != nil,
              command.allowed(ringing: state["ringing"] as? Bool ?? false,
                              inSession: state["inSession"] as? Bool ?? false, paused: paused, stopping: stopping) else {
            notice("Komut uygulanmadı: etkin arama durumunu kontrol edin.", to: client); return
        }
        switch command {
        case .answer: onAnswer?()
        case .end: onEnd?()
        case .note(let text): onNote?(text)
        case .ping, .pause: break
        }
    }
    private func notice(_ text: String, to client: MobileClient) {
        let id = noticeSequence; noticeSequence -= 1
        client.send(["t": "line", "id": id, "kind": "note", "speaker": "", "text": text, "ts": Date().timeIntervalSince1970])
    }
    private func broadcast(_ obj: [String: Any]) { for client in clients where client.ready { client.send(obj) } }
    func setState(inSession: Bool, caller: String, startedAt: Date?, status: String, ringing: Bool, ringer: String,
                  context: String?, paused: Bool, stopping: Bool, source: String = "", humanCall: Bool = false) {
        self.context = context; self.paused = paused; self.stopping = stopping
        var next: [String: Any] = ["t": "state", "inSession": inSession, "caller": caller, "status": status, "ringing": ringing, "ringer": ringer,
                                   "source": source, "paused": paused, "humanCall": humanCall]
        if let start = startedAt { next["startedAt"] = start.timeIntervalSince1970 }
        guard !NSDictionary(dictionary: state).isEqual(to: next) || clients.contains(where: { $0.context != context }) else { return }
        state = next
        for client in clients where client.ready { client.context = context; client.send(next) }
    }
    func reset() { transcript.reset(); broadcast(["t": "reset"]) }
    func setQuickNotes(_ notes: [String]) {
        guard notes != quickNotes else { return }
        quickNotes = notes; broadcast(["t": "quickNotes", "items": notes])
    }
    /// fresh: a call summary was just saved; the phone shows the newest item as the call's summary.
    func setHistory(_ items: [[String: Any]], fresh: Bool) {
        history = items; broadcast(["t": "history", "items": items, "fresh": fresh])
    }
    func append(kind: String, speaker: String, text: String) {
        let previousCount = transcript.lines.count
        let row = transcript.append(kind: kind, speaker: speaker, text: text)
        // A byte limit may evict old rows before the 200-row limit. Keep iOS bounded too.
        if transcript.lines.count <= previousCount { broadcast(["t": "snapshot", "lines": transcript.lines]) }
        else { var obj = row; obj["t"] = "line"; broadcast(obj) }
    }
    func replace(_ rows: [(String, String, String)]) {
        transcript.replace(rows); broadcast(["t": "snapshot", "lines": transcript.lines])
    }
}

import Cocoa
import CoreAudio

// MARK: - Ses kullanan süreçler (tanı)

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

/// Hangi süreçler şu an ses girişi/çıkışı kullanıyor (macOS 14.2+)
func audioProcessReport() -> String {
    var addr = AudioObjectPropertyAddress(mSelector: fourCC("prs#"), mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(hwSystem, &addr, 0, nil, &size) == noErr, size > 0 else { return "(süreç listesi yok)" }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(hwSystem, &addr, 0, nil, &size, &ids) == noErr else { return "(okunamadı)" }
    var out: [String] = []
    for id in ids {
        func u32(_ sel: String) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: fourCC(sel), mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0; var sz = UInt32(4)
            _ = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v)
            return v
        }
        var bid = ""
        var a = AudioObjectPropertyAddress(mSelector: fourCC("pbid"), mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if withUnsafeMutablePointer(to: &cf, { AudioObjectGetPropertyData(id, &a, 0, nil, &sz, $0) }) == noErr, let c = cf { bid = c.takeRetainedValue() as String }
        let rin = u32("piri"), rout = u32("piro")
        if rin != 0 || rout != 0 { out.append("\(bid)(pid \(u32("ppid")))\(rin != 0 ? " GİRİŞ" : "")\(rout != 0 ? " ÇIKIŞ" : "")") }
    }
    return out.isEmpty ? "(kimse ses kullanmıyor)" : out.joined(separator: "; ")
}

var defaultListenerInstalled = false
func installDefaultListeners() {
    guard !defaultListenerInstalled else { return }
    defaultListenerInstalled = true
    for (sel, name) in [(kAudioHardwarePropertyDefaultInputDevice, "giriş"), (kAudioHardwarePropertyDefaultOutputDevice, "çıkış")] {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(hwSystem, &addr, DispatchQueue.main) { _, _ in
            let d = getDefault(sel).map(deviceName) ?? "?"
            logLine("[izleme] varsayılan \(name) -> \(d) | ses kullananlar: \(audioProcessReport())")
        }
    }
}

// MARK: - Ses cihazları (CoreAudio)

let hwSystem = AudioObjectID(kAudioObjectSystemObject)

func deviceID(forUID uid: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = withUnsafeMutablePointer(to: &cfUID) { p in
        AudioObjectGetPropertyData(hwSystem, &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
    }
    return (st == noErr && dev != 0) ? dev : nil
}

func getDefault(_ sel: AudioObjectPropertySelector) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioObjectGetPropertyData(hwSystem, &addr, 0, nil, &size, &dev)
    return (st == noErr && dev != 0) ? dev : nil
}

@discardableResult
func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(hwSystem, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(hwSystem, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func hasStreams(_ d: AudioDeviceID, input: Bool) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size) == noErr && size > 0
}

func transportType(_ d: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &t)
    return t
}

func deviceUIDString(_ d: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(d, &addr, 0, nil, &size, $0) }
    if st == noErr, let u = cf { return u.takeRetainedValue() as String }
    return ""
}

func deviceName(_ d: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(d, &addr, 0, nil, &size, $0) }
    if st == noErr, let u = cf { return u.takeRetainedValue() as String }
    return deviceUIDString(d)
}

func builtinDevice(input: Bool) -> AudioDeviceID? {
    allDevices().first { hasStreams($0, input: input) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
}

func namedAudioDevice(_ name: String, input: Bool) -> AudioDeviceID? {
    let matches = allDevices().filter { deviceName($0) == name && hasStreams($0, input: input) }
    return matches.count == 1 ? matches[0] : nil
}

func loopbackAudioReady() -> Bool {
    guard let listen = namedAudioDevice(BetaAudio.listenName, input: true),
          let microphone = namedAudioDevice(BetaAudio.microphoneName, input: true),
          let playback = namedAudioDevice(BetaAudio.playbackName, input: false) else { return false }
    return Set([listen, microphone, playback]).count == 3
}

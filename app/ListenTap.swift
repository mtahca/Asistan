import CoreAudio
import Foundation

/// "Asistan Dinleme": arayanın sesi, Loopback olmadan. Core Audio process tap (macOS 14.2+) tüm
/// sistem sesini dinler, Asistan'ın kendi süreçlerini (uygulama ve ses ajanı) hariç tutar ve bunu
/// herkese açık bir toplu aygıt olarak sunar; ses ajanı aygıtı adıyla açar.
/// Arama uygulamalarının sesi süreç bazında yakalanamadı (FaceTime'da sessizlik), tüm sistem
/// sesi ise yakalandı (2026-10-10, Asistan-Audio-Driver deneyleri).
/// Ajan aygıtı açtığı sürece yakalanan ses hoparlörden kesilir (Loopback'teki "Mute when capturing");
/// görüşme bitince veya Devral'da ajan aygıtı kapatır ve ses hoparlöre döner.
final class ListenTap {
    static let shared = ListenTap()
    static let deviceUID = "com.mtahca.asistan.listen"
    /// "Asistan Sanal Çıkış": sürücü kuruluyken her zaman var; toplu aygıta sabit saat sağlar.
    static let clockUID = "AsistanSes_2_UID"

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var applied: [AudioObjectID] = []
    private var timer: Timer?
    private let tapUUID = UUID()
    private var excludedPIDs: Set<pid_t> = []
    private(set) var failure: String?

    var running: Bool { aggregateID != kAudioObjectUnknown }

    /// Hariç tutulacak süreçler: bu uygulama ve verilen ajan süreci.
    private func excludedObjects() -> [AudioObjectID] {
        let pids = excludedPIDs.union([getpid()])
        return pids.sorted().compactMap { pid in
            var p = pid, object = AudioObjectID(kAudioObjectUnknown)
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(hwSystem, &a, UInt32(MemoryLayout<pid_t>.size), &p, &size, &object)
            return status == noErr && object != kAudioObjectUnknown ? object : nil
        }
    }

    @available(macOS 14.2, *)
    private func description(_ excluded: [AudioObjectID]) -> CATapDescription {
        let d = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        d.uuid = tapUUID
        d.name = BetaAudio.listenName
        d.isPrivate = false
        d.muteBehavior = .mutedWhenTapped
        return d
    }

    /// Aygıtı oluşturur; zaten varsa bir şey yapmaz. Ajan başlamadan önce çağrılmalı: ajan aygıtları
    /// açılışta bir kez listeler.
    @discardableResult func start() -> Bool {
        guard !running else { return true }
        guard #available(macOS 14.2, *) else { failure = "macOS 14.2 veya sonrası gerekir"; return false }
        // Önceki bir çalışmadan kalan aygıtı kaldır.
        for device in allDevices() where deviceUIDString(device) == Self.deviceUID { AudioHardwareDestroyAggregateDevice(device) }
        applied = excludedObjects()
        var status = AudioHardwareCreateProcessTap(description(applied), &tapID)
        guard status == noErr else { failure = "Ses yakalama başlatılamadı (\(status)); Sistem sesi kaydetme iznini kontrol edin"; tapID = AudioObjectID(kAudioObjectUnknown); return false }
        var a = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        _ = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, $0) }
        guard let tapUID = uid?.takeRetainedValue() as String? else { stop(); failure = "Ses yakalama kimliği okunamadı"; return false }
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: BetaAudio.listenName,
            kAudioAggregateDeviceUIDKey: Self.deviceUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        if deviceID(forUID: Self.clockUID) != nil {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = Self.clockUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: Self.clockUID]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); failure = "Asistan Dinleme aygıtı oluşturulamadı (\(status))"; return false }
        failure = nil
        // Bir süreç ancak sesi kullanmaya başlayınca Core Audio'da görünür; ajan da açılıştan sonra
        // görünür. Hariç tutma listesini o zaman güncelle.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshExclusions() }
        return true
    }

    /// Ses ajanı yeniden başladığında yeni sürecini hariç tutar; kendi sesini dinlemesin.
    func exclude(agent pid: pid_t?) {
        excludedPIDs = pid.map { [$0] } ?? []
        refreshExclusions()
    }

    private func refreshExclusions() {
        guard tapID != kAudioObjectUnknown, #available(macOS 14.2, *) else { return }
        let excluded = excludedObjects()
        guard excluded != applied else { return }
        var a = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d = description(excluded)
        let status = withUnsafeMutablePointer(to: &d) {
            AudioObjectSetPropertyData(tapID, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr { applied = excluded } else { logLine("Asistan Dinleme: hariç tutma listesi güncellenemedi (\(status))") }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown); applied = []
    }
}

import CoreAudio
import Foundation

/// Un dispositivo audio Core Audio.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let outputChannels: Int
    let inputChannels: Int
    /// Driver del dispositivo: identificativo del plug-in Core Audio che lo possiede
    /// (kAudioObjectPropertyOwner -> kAudioPlugInPropertyBundleID), es. "audio.existential.BlackHole2ch";
    /// "com.apple.…" per i driver Apple. (kAudioObjectPropertyCreator non basta: sui macOS recenti
    /// restituisce il servizio di sistema che ospita i driver anche per quelli di terze parti.)
    var creator: String = ""
    /// Sorgente attiva dell'uscita (es. "Altoparlanti interni", "Cuffie"), se il dispositivo ne ha.
    var dataSource: String?

    /// Dispositivo creato da un driver Apple, non da un driver software di terze parti.
    var isAppleDriver: Bool {
        creator.hasPrefix("com.apple.") || (creator.isEmpty && transportType != kAudioDeviceTransportTypeVirtual)
    }

    /// Uscita integrata reale del Mac (altoparlanti interni / uscita cuffie): hardware integrato con
    /// driver Apple. Un driver di terze parti che si dichiara "integrato" NON è considerato tale.
    var isBuiltInHardware: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn && isAppleDriver && !isLoopback && !isAggregate
    }

    /// Nome come in macOS, con la sorgente attiva se diversa (es. "Uscita integrata – Altoparlanti interni").
    var displayName: String {
        guard let ds = dataSource, !ds.isEmpty, ds.caseInsensitiveCompare(name) != .orderedSame else { return name }
        return "\(name) – \(ds)"
    }

    var driverLabel: String {
        isAppleDriver ? "driver Apple" : "driver software di terze parti (\(creator.isEmpty ? "sconosciuto" : creator))"
    }

    /// Driver loopback usato per catturare l'audio di sistema (BlackHole o simili).
    var isLoopback: Bool {
        let n = name.lowercased(), u = uid.lowercased()
        return n.contains("blackhole") || u.contains("blackhole")
    }

    var isAggregate: Bool {
        transportType == kAudioDeviceTransportTypeAggregate
            || transportType == kAudioDeviceTransportTypeAutoAggregate
            || uid.hasPrefix(AudioRouter.aggregateUIDPrefix)
    }

    /// Dispositivo selezionabile come uscita reale.
    var isSelectableOutput: Bool {
        outputChannels > 0 && !isLoopback && !isAggregate
            && transportType != kAudioDeviceTransportTypeVirtual
    }

    var transportLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Integrato"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeVirtual: return "Virtuale"
        default: return "Audio"
        }
    }
}

enum AudioScope {
    case input, output
    var value: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }
}

struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus
    init(_ message: String, _ status: OSStatus = 0) {
        self.message = message
        self.status = status
    }
    var errorDescription: String? {
        status == 0 ? message : "\(message) (codice \(status) \(CoreAudioError.fourCC(status)))"
    }
    static func fourCC(_ s: OSStatus) -> String {
        let v = UInt32(bitPattern: s)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((v >> UInt32($0)) & 0xFF))) }
        return chars.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") }) ? "'\(String(chars))'" : ""
    }
}

/// Funzioni di utilità sull'API C di Core Audio (HAL).
enum CA {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func getValue<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) -> T? {
        var a = addr
        var v = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &v) { ptr in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, ptr)
        }
        return status == noErr ? v : nil
    }

    @discardableResult
    static func setValue<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = addr
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &v) { ptr in
            AudioObjectSetPropertyData(object, &a, 0, nil, size, ptr)
        }
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, ptr)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func getArray<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of type: T.Type, zero: T) -> [T] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        var result = [T](repeating: zero, count: count)
        let status = result.withUnsafeMutableBytes { buf in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(result.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    // MARK: Dispositivi

    static func allDeviceIDs() -> [AudioDeviceID] {
        getArray(systemObject, address(kAudioHardwarePropertyDevices), of: AudioDeviceID.self, zero: 0)
    }

    static func channelCount(_ device: AudioDeviceID, scope: AudioScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: scope.value)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func device(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = getString(id, kAudioObjectPropertyName) ?? uid
        let transport = getValue(id, address(kAudioDevicePropertyTransportType), default: UInt32(0)) ?? 0
        let outCh = channelCount(id, scope: .output)
        return AudioDevice(id: id, uid: uid, name: name, transportType: transport,
                           outputChannels: outCh,
                           inputChannels: channelCount(id, scope: .input),
                           creator: driverBundleID(id),
                           dataSource: outCh > 0 ? dataSourceName(id, scope: .output) : nil)
    }

    /// Identificativo del driver che possiede il dispositivo (vedi AudioDevice.creator):
    /// 1) catena dei proprietari (kAudioObjectPropertyOwner) fino a un oggetto plug-in;
    /// 2) elenco dei plug-in di Core Audio e dei loro dispositivi;
    /// 3) in mancanza, kAudioObjectPropertyCreator.
    static func driverBundleID(_ device: AudioDeviceID) -> String {
        func isPlugIn(_ obj: AudioObjectID) -> Bool {
            let cls = getValue(obj, address(kAudioObjectPropertyClass), default: AudioClassID(0))
            let base = getValue(obj, address(kAudioObjectPropertyBaseClass), default: AudioClassID(0))
            return cls == kAudioPlugInClassID || base == kAudioPlugInClassID
        }
        var obj = device
        for _ in 0..<4 {
            guard let owner = getValue(obj, address(kAudioObjectPropertyOwner), default: AudioObjectID(0)),
                  owner != 0, owner != systemObject, owner != obj else { break }
            if isPlugIn(owner), let bundle = getString(owner, kAudioPlugInPropertyBundleID), !bundle.isEmpty { return bundle }
            obj = owner
        }
        if let bundle = plugInBundleByDevice()[device] { return bundle }
        return getString(device, kAudioObjectPropertyCreator) ?? ""
    }

    /// Mappa dispositivo -> identificativo del plug-in, dall'elenco dei plug-in di Core Audio.
    static func plugInBundleByDevice() -> [AudioDeviceID: String] {
        var map: [AudioDeviceID: String] = [:]
        let plugins = getArray(systemObject, address(kAudioHardwarePropertyPlugInList), of: AudioObjectID.self, zero: 0)
        for p in plugins {
            guard let bundle = getString(p, kAudioPlugInPropertyBundleID), !bundle.isEmpty else { continue }
            for d in getArray(p, address(kAudioPlugInPropertyDeviceList), of: AudioObjectID.self, zero: 0) { map[d] = bundle }
        }
        return map
    }

    /// Diagnostica: catena dei proprietari di un oggetto (classe e identificativo).
    static func ownerChain(_ device: AudioDeviceID) -> String {
        var parts: [String] = []
        var obj = device
        for _ in 0..<4 {
            guard let owner = getValue(obj, address(kAudioObjectPropertyOwner), default: AudioObjectID(0)), owner != 0, owner != obj else { break }
            let cls = getValue(owner, address(kAudioObjectPropertyClass), default: AudioClassID(0)) ?? 0
            parts.append("\(owner):\(CoreAudioError.fourCC(OSStatus(bitPattern: cls)))\(getString(owner, kAudioPlugInPropertyBundleID).map { "(\($0))" } ?? "")")
            if owner == systemObject { break }
            obj = owner
        }
        return parts.joined(separator: " → ")
    }

    /// Nome della sorgente attiva (kAudioDevicePropertyDataSource), es. "Altoparlanti interni".
    static func dataSourceName(_ device: AudioDeviceID, scope: AudioScope) -> String? {
        let a = address(kAudioDevicePropertyDataSource, scope: scope.value)
        guard hasProperty(device, a), var sourceID = getValue(device, a, default: UInt32(0)) else { return nil }
        var name: Unmanaged<CFString>?
        var translation = AudioValueTranslation(mInputData: &sourceID, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                                mOutputData: &name, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
        var t = address(kAudioDevicePropertyDataSourceNameForIDCFString, scope: scope.value)
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        guard AudioObjectGetPropertyData(device, &t, 0, nil, &size, &translation) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    static func allDevices() -> [AudioDevice] {
        allDeviceIDs().compactMap { device($0) }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDevices().first(where: { $0.uid == uid })?.id
    }

    static func isAlive(_ device: AudioDeviceID) -> Bool {
        (getValue(device, address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0)) ?? 0) != 0
    }

    // MARK: Uscita predefinita di sistema

    static func defaultOutputDevice() -> AudioDeviceID? {
        getValue(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioDeviceID(0))
    }

    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioDeviceID) -> OSStatus {
        setValue(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    // MARK: Frequenza di campionamento e buffer

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        getValue(device, address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
    }

    @discardableResult
    static func setNominalSampleRate(_ device: AudioDeviceID, _ rate: Double) -> OSStatus {
        setValue(device, address(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    static func supportsSampleRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
        let ranges = getArray(device, address(kAudioDevicePropertyAvailableNominalSampleRates),
                              of: AudioValueRange.self, zero: AudioValueRange(mMinimum: 0, mMaximum: 0))
        return ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 }
    }

    @discardableResult
    static func setBufferFrameSize(_ device: AudioDeviceID, _ frames: UInt32) -> OSStatus {
        setValue(device, address(kAudioDevicePropertyBufferFrameSize), frames)
    }

    static func bufferFrameSize(_ device: AudioDeviceID) -> UInt32? {
        getValue(device, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0))
    }

    static func latencyFrames(_ device: AudioDeviceID, scope: AudioScope) -> UInt32 {
        let lat = getValue(device, address(kAudioDevicePropertyLatency, scope: scope.value), default: UInt32(0)) ?? 0
        let safety = getValue(device, address(kAudioDevicePropertySafetyOffset, scope: scope.value), default: UInt32(0)) ?? 0
        return lat + safety
    }

    /// Coppia stereo preferita del dispositivo (indici 0-based).
    static func preferredStereoChannels(_ device: AudioDeviceID) -> (Int, Int)? {
        let ch = getArray(device, address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput),
                          of: UInt32.self, zero: 0)
        guard ch.count == 2, ch[0] >= 1, ch[1] >= 1 else { return nil }
        return (Int(ch[0]) - 1, Int(ch[1]) - 1)
    }
}

// MARK: - Volume e mute dei dispositivi

extension CA {
    static func hasProperty(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(object, &a)
    }

    static func isSettable(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &a, &settable) == noErr && settable.boolValue
    }

    /// Elementi su cui agisce il controllo volume: il master se esiste, altrimenti i canali stereo.
    static func volumeElements(_ device: AudioDeviceID, scope: AudioScope,
                               selector: AudioObjectPropertySelector = kAudioDevicePropertyVolumeScalar) -> [AudioObjectPropertyElement] {
        let main = address(selector, scope: scope.value, element: kAudioObjectPropertyElementMain)
        if hasProperty(device, main) && isSettable(device, main) { return [kAudioObjectPropertyElementMain] }
        var channels: [AudioObjectPropertyElement] = [1, 2]
        if scope == .output, let (l, r) = preferredStereoChannels(device) {
            channels = [AudioObjectPropertyElement(l + 1), AudioObjectPropertyElement(r + 1)]
        }
        return channels.filter {
            let a = address(selector, scope: scope.value, element: $0)
            return hasProperty(device, a) && isSettable(device, a)
        }
    }

    /// true se il dispositivo ha un controllo volume hardware regolabile.
    static func hasSettableVolume(_ device: AudioDeviceID, scope: AudioScope) -> Bool {
        !volumeElements(device, scope: scope).isEmpty
    }

    static func volumeScalar(_ device: AudioDeviceID, scope: AudioScope) -> Float32? {
        let els = volumeElements(device, scope: scope)
        let values = els.compactMap {
            getValue(device, address(kAudioDevicePropertyVolumeScalar, scope: scope.value, element: $0), default: Float32(0))
        }
        return values.max()
    }

    @discardableResult
    static func setVolumeScalar(_ device: AudioDeviceID, scope: AudioScope, _ value: Float32) -> Bool {
        let v = min(max(value, 0), 1)
        var ok = false
        for el in volumeElements(device, scope: scope) {
            ok = setValue(device, address(kAudioDevicePropertyVolumeScalar, scope: scope.value, element: el), v) == noErr || ok
        }
        return ok
    }

    /// Guadagno reale (in dB) applicato dal controllo volume del dispositivo.
    static func volumeDecibels(_ device: AudioDeviceID, scope: AudioScope) -> Float32? {
        for el in [kAudioObjectPropertyElementMain, 1] as [AudioObjectPropertyElement] {
            let a = address(kAudioDevicePropertyVolumeDecibels, scope: scope.value, element: el)
            if hasProperty(device, a), let db = getValue(device, a, default: Float32(0)) { return db }
        }
        return nil
    }

    /// Conversione scalare -> dB secondo la curva del controllo volume del dispositivo, SENZA
    /// modificarne il volume (proprietà di traduzione di Core Audio). nil se non disponibile.
    static func volumeScalarToDecibels(_ device: AudioDeviceID, scope: AudioScope, _ scalar: Float32) -> Float32? {
        for el in volumeElements(device, scope: scope) {
            var a = address(kAudioDevicePropertyVolumeScalarToDecibels, scope: scope.value, element: el)
            guard hasProperty(device, a) else { continue }
            var v = min(max(scalar, 0), 1)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr, v.isFinite { return v }
        }
        return nil
    }

    /// Intervallo in dB del controllo volume (es. BlackHole: -64...0).
    static func volumeDecibelRange(_ device: AudioDeviceID, scope: AudioScope) -> (min: Float32, max: Float32)? {
        for el in volumeElements(device, scope: scope) {
            let a = address(kAudioDevicePropertyVolumeRangeDecibels, scope: scope.value, element: el)
            if hasProperty(device, a), let r = getValue(device, a, default: AudioValueRange(mMinimum: 0, mMaximum: 0)),
               r.mMaximum > r.mMinimum {
                return (Float32(r.mMinimum), Float32(r.mMaximum))
            }
        }
        return nil
    }

    static func isMuted(_ device: AudioDeviceID, scope: AudioScope) -> Bool? {
        let a = address(kAudioDevicePropertyMute, scope: scope.value)
        guard hasProperty(device, a), let v = getValue(device, a, default: UInt32(0)) else { return nil }
        return v != 0
    }

    @discardableResult
    static func setMuted(_ device: AudioDeviceID, scope: AudioScope, _ muted: Bool) -> Bool {
        let a = address(kAudioDevicePropertyMute, scope: scope.value)
        guard hasProperty(device, a), isSettable(device, a) else { return false }
        return setValue(device, a, UInt32(muted ? 1 : 0)) == noErr
    }

    /// Guadagno lineare che un driver loopback applica al segnale catturato a causa del suo
    /// controllo volume (BlackHole moltiplica i campioni per questo valore). 1 se non ha controllo.
    static func loopbackCaptureGain(_ device: AudioDeviceID) -> Float32 {
        if isMuted(device, scope: .output) == true { return 0 }
        guard let scalar = volumeScalar(device, scope: .output) else { return 1 }
        if scalar <= 0 { return 0 }
        guard let db = volumeDecibels(device, scope: .output) else { return 1 }
        return powf(10, db / 20)
    }
}

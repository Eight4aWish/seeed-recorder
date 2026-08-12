// Lists CoreAudio input devices and CoreMIDI sources/destinations.
// Audio devices are exposed as (id, name); MIDI as names only since CoreMIDI
// endpoint refs aren't useful to pass around in our UI.

import Foundation
import CoreAudio
import CoreMIDI

@MainActor
final class DeviceEnumerator: ObservableObject {
    @Published private(set) var audioInputs: [AudioInputDevice] = []
    /// Monitoring devices for the review window. Separate from `audioInputs`
    /// because a device can offer both directions (the Scarlett does) and the
    /// two pickers must not be interchangeable.
    @Published private(set) var audioOutputs: [AudioOutputDevice] = []
    @Published private(set) var midiSources: [String] = []
    @Published private(set) var midiDestinations: [String] = []

    init() {
        refresh()
    }

    func refresh() {
        audioInputs = Self.listAudioInputs()
        audioOutputs = Self.listAudioOutputs()
        midiSources = Self.listMIDIEndpoints(sources: true)
        midiDestinations = Self.listMIDIEndpoints(sources: false)
    }

    // MARK: - CoreAudio

    private static func listAudioInputs() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasChannels(id, scope: kAudioDevicePropertyScopeInput),
                  let name = deviceName(id) else { return nil }
            return AudioInputDevice(id: id, uid: deviceUID(id), name: name)
        }
    }

    private static func listAudioOutputs() -> [AudioOutputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasChannels(id, scope: kAudioDevicePropertyScopeOutput),
                  let name = deviceName(id) else { return nil }
            return AudioOutputDevice(id: id, uid: deviceUID(id), name: name)
        }
    }

    /// The system's default output — what the review window monitors through
    /// unless the user picks something else.
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else {
            return nil
        }
        let s = uid as String
        return s.isEmpty ? nil : s
    }

    private static func hasChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return false
        }

        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }
        return name as String
    }

    // MARK: - CoreMIDI

    private static func listMIDIEndpoints(sources: Bool) -> [String] {
        let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        var names: [String] = []
        names.reserveCapacity(count)

        for i in 0..<count {
            let endpoint: MIDIEndpointRef = sources ? MIDIGetSource(i) : MIDIGetDestination(i)
            var cfname: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfname)
            if status == noErr, let s = cfname?.takeRetainedValue() as String? {
                names.append(s)
            }
        }
        return names
    }
}

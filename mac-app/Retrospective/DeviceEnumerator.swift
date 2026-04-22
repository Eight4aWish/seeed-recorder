// Lists CoreAudio input devices and CoreMIDI sources/destinations by name.
// No I/O yet — this is just enough to populate Settings pickers.

import Foundation
import CoreAudio
import CoreMIDI

@MainActor
final class DeviceEnumerator: ObservableObject {
    @Published private(set) var audioInputs: [String] = []
    @Published private(set) var midiSources: [String] = []
    @Published private(set) var midiDestinations: [String] = []

    init() {
        refresh()
    }

    func refresh() {
        audioInputs = Self.listAudioInputs()
        midiSources = Self.listMIDIEndpoints(sources: true)
        midiDestinations = Self.listMIDIEndpoints(sources: false)
    }

    // MARK: - CoreAudio

    private static func listAudioInputs() -> [String] {
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

        return ids.compactMap { id in
            guard hasInputChannels(id) else { return nil }
            return deviceName(id)
        }
    }

    private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
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

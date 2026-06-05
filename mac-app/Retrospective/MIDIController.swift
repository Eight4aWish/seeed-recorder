// CoreMIDI client. Listens on the selected input source for the button-press
// note (channel 16, note 60). Sends Note On vel 127 / vel 1 to the selected
// destination to drive the LED on the Seeed.
//
// Channel + note are baked from the protocol described in CLAUDE.md.

import Foundation
import CoreMIDI
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "MIDI")

@MainActor
final class MIDIController: ObservableObject {
    nonisolated static let buttonChannel: UInt8 = 16   // 1..16 in MIDI parlance
    nonisolated static let buttonNote: UInt8 = 60

    @Published var sourceName: String? {
        didSet {
            persist(name: sourceName, key: "midiSourceName")
            if oldValue != sourceName { reconnectSource() }
        }
    }
    @Published var destinationName: String? {
        didSet {
            persist(name: destinationName, key: "midiDestinationName")
            if oldValue != destinationName { resolveDestination() }
        }
    }

    private func persist(name: String?, key: String) {
        if let n = name {
            UserDefaults.standard.set(n, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    @Published private(set) var lastError: String?

    /// Fired on the main actor when a button press (Note On vel > 0 on the configured channel/note) arrives.
    var onButtonPress: (() -> Void)?

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var connectedSource: MIDIEndpointRef = 0
    private var resolvedDestination: MIDIEndpointRef = 0

    init() {
        var clientRef: MIDIClientRef = 0
        let status = MIDIClientCreateWithBlock("Retrospective" as CFString, &clientRef) { [weak self] notification in
            // Could react to MIDI setup changes here (devices added/removed).
            _ = notification
            _ = self
        }
        guard status == noErr else {
            lastError = "MIDIClientCreate failed (\(status))"
            log.error("MIDIClientCreate failed: \(status, privacy: .public)")
            return
        }
        client = clientRef

        var input: MIDIPortRef = 0
        let inStatus = MIDIInputPortCreateWithProtocol(
            client, "Retrospective In" as CFString, ._1_0, &input
        ) { [weak self] eventList, _ in
            self?.handleEventList(eventList)
        }
        if inStatus == noErr {
            inputPort = input
        } else {
            lastError = "MIDIInputPortCreate failed (\(inStatus))"
        }

        var output: MIDIPortRef = 0
        let outStatus = MIDIOutputPortCreate(client, "Retrospective Out" as CFString, &output)
        if outStatus == noErr {
            outputPort = output
        } else {
            lastError = "MIDIOutputPortCreate failed (\(outStatus))"
        }

        // Restore persisted MIDI source/destination. didSet doesn't fire from
        // inside init, so we set the stored values then trigger reconnect/resolve
        // manually now that the input/output ports are ready.
        sourceName = UserDefaults.standard.string(forKey: "midiSourceName")
        destinationName = UserDefaults.standard.string(forKey: "midiDestinationName")
        if sourceName != nil { reconnectSource() }
        if destinationName != nil { resolveDestination() }
    }

    deinit {
        if connectedSource != 0, inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, connectedSource)
        }
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Source

    private func reconnectSource() {
        if connectedSource != 0 {
            MIDIPortDisconnectSource(inputPort, connectedSource)
            connectedSource = 0
        }
        guard let name = sourceName, let endpoint = endpointForSource(named: name) else { return }
        let status = MIDIPortConnectSource(inputPort, endpoint, nil)
        if status == noErr {
            connectedSource = endpoint
            log.info("MIDI source connected: \(name, privacy: .public)")
        } else {
            lastError = "MIDIPortConnectSource failed (\(status))"
        }
    }

    // MARK: - Destination

    private func resolveDestination() {
        resolvedDestination = 0
        guard let name = destinationName, let endpoint = endpointForDestination(named: name) else { return }
        resolvedDestination = endpoint
        log.info("MIDI destination resolved: \(name, privacy: .public)")
    }

    func sendLEDOn()    { sendNoteOn(velocity: 127) }
    func sendLEDOff()   { sendNoteOn(velocity: 1) }
    func sendLEDError() { sendNoteOn(velocity: 64) }   // sticky 1 Hz blink

    private func sendNoteOn(velocity: UInt8) {
        guard outputPort != 0, resolvedDestination != 0 else { return }

        // MIDI 1.0 Note On: status byte = 0x90 | (channel-1)
        let status: UInt8 = 0x90 | (Self.buttonChannel - 1)
        let bytes: [UInt8] = [status, Self.buttonNote, velocity]

        var packetList = MIDIPacketList()
        let pkt = MIDIPacketListInit(&packetList)
        _ = bytes.withUnsafeBufferPointer { bp in
            MIDIPacketListAdd(&packetList, 1024, pkt, 0, bytes.count, bp.baseAddress!)
        }
        let s = MIDISend(outputPort, resolvedDestination, &packetList)
        if s != noErr {
            log.error("MIDISend failed (\(s, privacy: .public))")
        }
    }

    // MARK: - Inbound parsing

    private nonisolated func handleEventList(_ eventList: UnsafePointer<MIDIEventList>) {
        // MIDI 1.0 over UMP: a Channel Voice message fits in one 32-bit word.
        // Walk the variable-length packet list using MIDIEventPacketNext, which
        // returns a pointer into the OS-owned event list memory.
        let numPackets = Int(eventList.pointee.numPackets)
        guard numPackets > 0 else { return }

        let listMutable = UnsafeMutablePointer(mutating: eventList)
        withUnsafeMutablePointer(to: &listMutable.pointee.packet) { firstPkt in
            var packetPtr = firstPkt
            for _ in 0..<numPackets {
                let wordCount = min(Int(packetPtr.pointee.wordCount), 64)
                if wordCount > 0 {
                    withUnsafeBytes(of: packetPtr.pointee.words) { rawBuf in
                        let words = rawBuf.bindMemory(to: UInt32.self)
                        for i in 0..<wordCount {
                            processWord1_0(words[i])
                        }
                    }
                }
                packetPtr = MIDIEventPacketNext(packetPtr)
            }
        }
    }

    private nonisolated func processWord1_0(_ word: UInt32) {
        // For MIDI 1.0 Channel Voice in UMP form (message type 0x2):
        //   byte0: 0x2X        where X is group (cable)
        //   byte1: status (0x90 = Note On, 0x80 = Note Off, ...)
        //   byte2: data1 (note number)
        //   byte3: data2 (velocity)
        let mt = (word >> 28) & 0xF
        guard mt == 0x2 else { return }    // only handle MIDI 1.0 channel voice
        let status   = UInt8((word >> 16) & 0xFF)
        let data1    = UInt8((word >> 8)  & 0xFF)
        let data2    = UInt8( word        & 0xFF)
        let opcode   = status & 0xF0
        let channel  = (status & 0x0F) + 1   // 1..16

        guard channel == Self.buttonChannel, data1 == Self.buttonNote else { return }

        // The firmware only ever sends vel 127 for a real button press. Any other
        // value (including the vel 1 we use for LED-off) must NOT be treated as a
        // press, otherwise our own LED-off command can echo back and re-trigger.
        let isPress = (opcode == 0x90 && data2 == 127)
        log.info("MIDI in: opcode=\(opcode, format: .hex, privacy: .public) ch=\(channel, privacy: .public) note=\(data1, privacy: .public) vel=\(data2, privacy: .public) press=\(isPress, privacy: .public)")
        guard isPress else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onButtonPress?()
        }
    }

    // MARK: - Endpoint lookup

    private func endpointForSource(named name: String) -> MIDIEndpointRef? {
        for i in 0..<MIDIGetNumberOfSources() {
            let ep = MIDIGetSource(i)
            if Self.endpointName(ep) == name { return ep }
        }
        return nil
    }

    private func endpointForDestination(named name: String) -> MIDIEndpointRef? {
        for i in 0..<MIDIGetNumberOfDestinations() {
            let ep = MIDIGetDestination(i)
            if Self.endpointName(ep) == name { return ep }
        }
        return nil
    }

    private static func endpointName(_ ep: MIDIEndpointRef) -> String? {
        var cf: Unmanaged<CFString>?
        let s = MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &cf)
        guard s == noErr, let v = cf?.takeRetainedValue() else { return nil }
        return v as String
    }
}

// CoreAudio capture: open input device, run an IOProc on the audio thread,
// push interleaved frames into a ScratchBuffer (RAM ring + on-disk circular files).
//
// Concurrency:
//   - main actor: lifecycle (start/stop) and @Published UI state
//   - IOProc: real-time audio thread, NO allocation / locks / blocking
//   - scratch writer: dispatch queue at userInitiated, pwrite()s to disk
//
// The IOProc shares state via a heap-allocated context struct passed as a raw
// pointer. AudioDeviceDestroyIOProcID guarantees the callback has finished
// before returning, which is when we tear the context down.

import Foundation
import CoreAudio
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "AudioCapture")

private struct IOProcContext {
    var frameCounter: UInt64
    var bytesPerFrame: UInt32
    var scratchBufferRaw: UnsafeMutableRawPointer?
}

@MainActor
final class AudioCaptureEngine: ObservableObject {
    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var channelCount: Int = 0
    @Published private(set) var bitsPerChannel: Int = 0
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var scratchPath: String?
    @Published private(set) var lastError: String?

    @Published var lookbackSeconds: Double {
        didSet {
            UserDefaults.standard.set(lookbackSeconds, forKey: "lookbackSeconds")
        }
    }

    @Published var selectedDevice: AudioInputDevice? {
        didSet {
            // Persist the device's stable UID, not its AudioDeviceID
            // (which can change across launches / unplugs).
            if let uid = selectedDevice?.uid {
                UserDefaults.standard.set(uid, forKey: "audioInputUID")
            } else if selectedDevice == nil {
                UserDefaults.standard.removeObject(forKey: "audioInputUID")
            }
            if oldValue?.id == selectedDevice?.id { return }
            stop()
            if let dev = selectedDevice {
                start(deviceID: dev.id)
            }
        }
    }

    init() {
        let stored = UserDefaults.standard.double(forKey: "lookbackSeconds")
        self.lookbackSeconds = stored > 0 ? stored : 60   // 1 min default
    }

    private var activeDeviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var contextPtr: UnsafeMutablePointer<IOProcContext>?
    private(set) var scratchBuffer: ScratchBuffer?
    private var lastFrameCount: UInt64 = 0
    private var rateTimer: DispatchSourceTimer?

    func start(deviceID: AudioDeviceID) {
        guard !isCapturing else { return }
        lastError = nil

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        let fmtStatus = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &fmt)
        guard fmtStatus == noErr else {
            lastError = "Could not read input stream format (OSStatus \(fmtStatus))."
            return
        }
        guard fmt.mBytesPerFrame > 0, fmt.mChannelsPerFrame > 0 else {
            lastError = "Device reports invalid format."
            return
        }

        let isInterleaved = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        guard isInterleaved else {
            lastError = "Non-interleaved input streams are not supported yet."
            return
        }
        let isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        sampleRate = fmt.mSampleRate
        channelCount = Int(fmt.mChannelsPerFrame)
        bitsPerChannel = Int(fmt.mBitsPerChannel)

        // Build the scratch buffer up front so we can tear it down cleanly on any failure below.
        let scratch: ScratchBuffer
        do {
            scratch = try ScratchBuffer(
                channelCount: channelCount,
                sampleRate: sampleRate,
                bitsPerChannel: bitsPerChannel,
                isFloat: isFloat,
                lookbackSeconds: lookbackSeconds)
        } catch {
            lastError = "Scratch buffer init failed: \(error.localizedDescription)"
            return
        }
        scratch.startWriter()

        let scratchPtr = Unmanaged.passUnretained(scratch).toOpaque()
        let ctx = UnsafeMutablePointer<IOProcContext>.allocate(capacity: 1)
        ctx.initialize(to: IOProcContext(
            frameCounter: 0,
            bytesPerFrame: fmt.mBytesPerFrame,
            scratchBufferRaw: scratchPtr))

        var procID: AudioDeviceIOProcID?
        let regStatus = AudioDeviceCreateIOProcID(deviceID, ioProc, ctx, &procID)
        guard regStatus == noErr, let procID else {
            scratch.stop()
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            lastError = "Could not register IOProc (OSStatus \(regStatus))."
            return
        }

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            scratch.stop()
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            lastError = "Could not start device (OSStatus \(startStatus))."
            return
        }

        activeDeviceID = deviceID
        ioProcID = procID
        contextPtr = ctx
        scratchBuffer = scratch
        scratchPath = scratch.directory.path
        lastFrameCount = 0
        isCapturing = true
        startRateTimer()

        log.info("Capture started: \(self.channelCount, privacy: .public) ch @ \(self.sampleRate, privacy: .public) Hz, \(self.bitsPerChannel, privacy: .public)-bit, lookback \(self.lookbackSeconds, privacy: .public) s")
    }

    func stop() {
        guard isCapturing else { return }
        rateTimer?.cancel()
        rateTimer = nil
        if let procID = ioProcID {
            AudioDeviceStop(activeDeviceID, procID)
            AudioDeviceDestroyIOProcID(activeDeviceID, procID)
            ioProcID = nil
        }
        if let scratch = scratchBuffer {
            scratch.stop()
            scratchBuffer = nil
        }
        if let ctx = contextPtr {
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            contextPtr = nil
        }
        activeDeviceID = 0
        isCapturing = false
        framesPerSecond = 0
        scratchPath = nil
        log.info("Capture stopped")
    }

    private func startRateTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let ctx = self.contextPtr else { return }
            let now = ctx.pointee.frameCounter
            let delta = now &- self.lastFrameCount
            self.lastFrameCount = now
            self.framesPerSecond = Double(delta)
        }
        timer.resume()
        rateTimer = timer
    }
}

// MARK: - IOProc (real-time audio thread)

private func ioProc(
    _ inDevice: AudioObjectID,
    _ inNow: UnsafePointer<AudioTimeStamp>,
    _ inInputData: UnsafePointer<AudioBufferList>,
    _ inInputTime: UnsafePointer<AudioTimeStamp>,
    _ outOutputData: UnsafeMutablePointer<AudioBufferList>,
    _ inOutputTime: UnsafePointer<AudioTimeStamp>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let raw = inClientData else { return noErr }
    let ctx = raw.assumingMemoryBound(to: IOProcContext.self)

    let buffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer<AudioBufferList>(mutating: inInputData))
    guard let first = buffers.first, let data = first.mData else { return noErr }

    let byteSize = Int(first.mDataByteSize)
    let bpf = ctx.pointee.bytesPerFrame
    if bpf > 0 {
        ctx.pointee.frameCounter &+= UInt64(byteSize) / UInt64(bpf)
    }

    if let scratchRaw = ctx.pointee.scratchBufferRaw {
        let scratch = Unmanaged<ScratchBuffer>.fromOpaque(scratchRaw).takeUnretainedValue()
        scratch.appendInterleaved(data, byteCount: byteSize)
    }
    return noErr
}

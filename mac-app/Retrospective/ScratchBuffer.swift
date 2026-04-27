// Rolling on-disk scratch buffer.
//
// One pre-allocated PCM file per channel under
// ~/Library/Application Support/Retrospective/scratch/, each sized to
// (lookback × sampleRate × bytesPerSample) bytes.
//
// Data path:
//   audio thread (IOProc)  -->  RAM ring (interleaved bytes)
//                                       |
//                                  writer queue (50 ms tick)
//                                       v
//                            de-interleave + pwrite to per-channel files
//
// Ring concurrency: SPSC, indices are `Atomic<UInt64>` with release/acquire
// ordering so the writer thread sees consistent data. The audio thread never
// allocates, locks, or blocks.

import Foundation
import CoreAudio
import OSLog
import os

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "ScratchBuffer")

struct ScratchFormat: Codable {
    var sampleRate: Double
    var bitsPerChannel: Int
    var bytesPerSample: Int
    var isFloat: Bool
    var channelCount: Int
    var lookbackSeconds: Double
    var framesPerFile: Int
    var startedAt: Date
}

final class ScratchBuffer: @unchecked Sendable {
    let directory: URL
    let format: ScratchFormat
    let bytesPerFrame: Int

    private let ringCapacity: Int
    private let ringStorage: UnsafeMutablePointer<UInt8>
    // Brief-acquisition leaf locks. Audio thread acquires only to update its
    // own index; writer thread does the same. No nested locks held.
    private let writeIndex = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let readIndex  = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private var fds: [Int32]
    private var frameWriteOffset: UInt64 = 0     // monotonic, modulo framesPerFile gives the current circular slot
    private let framesPerFile: UInt64

    private let writerQueue: DispatchQueue
    private var writerTimer: DispatchSourceTimer?
    private let deinterleaveBufferSize: Int
    private let deinterleaveBuffer: UnsafeMutablePointer<UInt8>
    private let perChannelChunkSize: Int
    private let perChannelChunk: UnsafeMutablePointer<UInt8>

    // Approx ring drain interval (ms). Smaller = lower buffer demand, more wakeups.
    private let drainIntervalMs: Int = 50

    init(channelCount: Int, sampleRate: Double, bitsPerChannel: Int, isFloat: Bool, lookbackSeconds: Double) throws {
        let bytesPerSample = (bitsPerChannel + 7) / 8
        precondition(channelCount > 0 && bytesPerSample > 0)

        self.bytesPerFrame = channelCount * bytesPerSample
        self.framesPerFile = UInt64(sampleRate * lookbackSeconds)
        let perChannelFileBytes = Int(framesPerFile) * bytesPerSample

        // RAM ring: ~3 seconds of audio, rounded up to a power-of-two for cheap modulo.
        // The 3-second headroom lets us pause the writer during extraction (~1 s of disk
        // I/O) without the IOProc dropping bytes.
        let targetBytes = Int(sampleRate) * bytesPerFrame * 3
        var capacity = 1
        while capacity < targetBytes { capacity <<= 1 }
        self.ringCapacity = capacity
        self.ringStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        self.ringStorage.initialize(repeating: 0, count: capacity)

        // De-interleave scratch — sized to drain interval × frame size, with margin.
        let drainBytes = (Int(sampleRate) * bytesPerFrame * (drainIntervalMs * 4)) / 1000 + bytesPerFrame
        self.deinterleaveBufferSize = drainBytes
        self.deinterleaveBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: drainBytes)

        self.perChannelChunkSize = (drainBytes / bytesPerFrame) * bytesPerSample
        self.perChannelChunk = UnsafeMutablePointer<UInt8>.allocate(capacity: perChannelChunkSize)

        // Scratch directory in Application Support.
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let scratchDir = supportDir.appendingPathComponent("Retrospective/scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        self.directory = scratchDir

        self.format = ScratchFormat(
            sampleRate: sampleRate,
            bitsPerChannel: bitsPerChannel,
            bytesPerSample: bytesPerSample,
            isFloat: isFloat,
            channelCount: channelCount,
            lookbackSeconds: lookbackSeconds,
            framesPerFile: Int(framesPerFile),
            startedAt: Date())

        // Pre-allocate per-channel scratch files.
        var openedFds: [Int32] = []
        openedFds.reserveCapacity(channelCount)
        for ch in 0..<channelCount {
            let url = scratchDir.appendingPathComponent(String(format: "ch%02d.pcm", ch))
            let fd = url.path.withCString { open($0, O_RDWR | O_CREAT, 0o644) }
            if fd < 0 {
                let err = String(cString: strerror(errno))
                openedFds.forEach { close($0) }
                throw NSError(domain: "ScratchBuffer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "open(\(url.path)) failed: \(err)"])
            }
            if ftruncate(fd, off_t(perChannelFileBytes)) != 0 {
                let err = String(cString: strerror(errno))
                close(fd)
                openedFds.forEach { close($0) }
                throw NSError(domain: "ScratchBuffer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "ftruncate failed: \(err)"])
            }
            openedFds.append(fd)
        }
        self.fds = openedFds

        // Persist format.json (small file, write once at start).
        let fmtURL = scratchDir.appendingPathComponent("format.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let fmtData = try encoder.encode(format)
        try fmtData.write(to: fmtURL, options: .atomic)

        self.writerQueue = DispatchQueue(label: "com.n8synth.retrospective.scratch-writer",
                                         qos: .userInitiated)

        log.info("Scratch ready: \(channelCount, privacy: .public) ch × \(perChannelFileBytes / 1_048_576, privacy: .public) MiB at \(scratchDir.path, privacy: .public)")
    }

    deinit {
        writerTimer?.cancel()
        fds.forEach { close($0) }
        ringStorage.deallocate()
        deinterleaveBuffer.deallocate()
        perChannelChunk.deallocate()
    }

    // MARK: - Audio thread (IOProc)

    /// Append one IOProc's worth of interleaved input bytes to the ring.
    /// Drops bytes silently if the ring is full (writer fell behind).
    /// Must be safe to call from a real-time audio thread: no allocation, no locks.
    @inline(__always)
    func appendInterleaved(_ src: UnsafeRawPointer, byteCount: Int) {
        guard byteCount > 0 else { return }

        let r = readIndex.withLock { $0 }
        let w = writeIndex.withLock { $0 }
        let used = Int(w &- r)
        let free = ringCapacity - used
        if free <= 0 { return }
        let toWrite = min(byteCount, free)

        let mask = UInt64(ringCapacity - 1)
        let writePos = Int(w & mask)
        let firstChunk = min(toWrite, ringCapacity - writePos)
        memcpy(ringStorage + writePos, src, firstChunk)
        if toWrite > firstChunk {
            memcpy(ringStorage, src.advanced(by: firstChunk), toWrite - firstChunk)
        }

        writeIndex.withLock { $0 = w &+ UInt64(toWrite) }
    }

    // MARK: - Writer thread

    func startWriter() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + .milliseconds(drainIntervalMs),
                       repeating: .milliseconds(drainIntervalMs),
                       leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.drain()
        }
        timer.resume()
        writerTimer = timer
    }

    func stop() {
        writerTimer?.cancel()
        writerTimer = nil
        // Final drain to flush any pending bytes.
        writerQueue.sync { [weak self] in
            self?.drain()
        }
    }

    /// Force a final drain and return the current circular write offset (frames).
    /// Safe to call from any thread; blocks until any pending writer block completes.
    func snapshotWriteOffset() -> UInt64 {
        writerQueue.sync {
            drain()
            return frameWriteOffset
        }
    }

    /// Stop the periodic drain. After this returns, no further writes happen to the
    /// per-channel scratch files. The IOProc keeps filling the RAM ring; if the ring
    /// fills before `resumeWriter()` is called, the IOProc starts dropping bytes.
    func pauseWriter() {
        writerTimer?.cancel()
        writerTimer = nil
        // Final flush so anything buffered in the RAM ring lands on disk before we read.
        writerQueue.sync { [weak self] in
            self?.drain()
        }
    }

    /// Resume the periodic drain after a pause. Picks up wherever the IOProc has gotten
    /// the ring to during the pause.
    func resumeWriter() {
        guard writerTimer == nil else { return }
        startWriter()
    }

    private func drain() {
        let w = writeIndex.withLock { $0 }
        let r = readIndex.withLock { $0 }
        let available = Int(w &- r)
        if available < bytesPerFrame { return }

        // Drain in chunks bounded by the de-interleave buffer.
        var consumed = 0
        let mask = UInt64(ringCapacity - 1)
        let bps = format.bytesPerSample
        let nch = format.channelCount

        while consumed + bytesPerFrame <= available {
            let chunkBytes = min(deinterleaveBufferSize, available - consumed)
            let frames = chunkBytes / bytesPerFrame
            let chunk = frames * bytesPerFrame
            if chunk == 0 { break }

            let pos = Int((r &+ UInt64(consumed)) & mask)
            let firstPart = min(chunk, ringCapacity - pos)
            memcpy(deinterleaveBuffer, ringStorage + pos, firstPart)
            if chunk > firstPart {
                memcpy(deinterleaveBuffer.advanced(by: firstPart),
                       ringStorage,
                       chunk - firstPart)
            }

            for ch in 0..<nch {
                // Pull this channel's samples out of the interleaved chunk.
                var dst = perChannelChunk
                var srcSample = deinterleaveBuffer.advanced(by: ch * bps)
                for _ in 0..<frames {
                    memcpy(dst, srcSample, bps)
                    dst = dst.advanced(by: bps)
                    srcSample = srcSample.advanced(by: bytesPerFrame)
                }

                writeChannelChunk(channel: ch, frames: frames)
            }

            frameWriteOffset = (frameWriteOffset &+ UInt64(frames)) % framesPerFile
            consumed += chunk
        }

        let newReadIndex = r &+ UInt64(consumed)
        readIndex.withLock { $0 = newReadIndex }
    }

    private func writeChannelChunk(channel: Int, frames: Int) {
        let bps = format.bytesPerSample
        let fileFrames = framesPerFile
        let startFrame = frameWriteOffset
        let endFrame = startFrame &+ UInt64(frames)

        let fd = fds[channel]

        if endFrame <= fileFrames {
            // No wrap.
            let offset = off_t(startFrame * UInt64(bps))
            let count = frames * bps
            _ = pwrite(fd, perChannelChunk, count, offset)
        } else {
            // Wrap — split into [start..end_of_file) and [0..remaining).
            let firstFrames = Int(fileFrames - startFrame)
            let secondFrames = frames - firstFrames

            let firstOffset = off_t(startFrame * UInt64(bps))
            _ = pwrite(fd, perChannelChunk, firstFrames * bps, firstOffset)

            _ = pwrite(fd,
                       perChannelChunk.advanced(by: firstFrames * bps),
                       secondFrames * bps,
                       0)
        }
    }
}

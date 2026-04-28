// On capture trigger:
//   1. Pause the scratch writer so the per-channel files are stable while we read.
//   2. Snapshot the current circular write offset (oldest-frame position).
//   3. For each channel in parallel: read chronologically, compute peak,
//      write a WAV if peak ≥ silence threshold.
//   4. Log peak dBFS for every channel (saved or skipped).
//   5. Resume the writer.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "Extractor")

struct ExtractionResult {
    let outputDirectory: URL
    let writtenFiles: [URL]
    let skippedSilentChannels: [Int]
    let peaksDBFS: [Float]   // -infinity for pure-silence channels; one entry per channel
    let channelErrors: [(channel: Int, message: String)]
}

private struct ChannelResult {
    let peakDBFS: Float
    let fileURL: URL?
    let errorMessage: String?
}

enum ScratchExtractor {
    /// Anything with peak below this is skipped as silence.
    static let silenceThresholdDBFS: Float = -60.0
    static let silenceThresholdLinear: Float = pow(10.0, silenceThresholdDBFS / 20.0)

    static func extract(
        scratch: ScratchBuffer,
        firstPressTime: Date,
        outputRoot: URL
    ) throws -> ExtractionResult {
        let format = scratch.format
        let framesPerFile = format.framesPerFile
        let bytesPerSample = format.bytesPerSample
        precondition(format.isFloat && bytesPerSample == 4, "Only Float32 capture is currently supported.")

        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        scratch.pauseWriter()
        defer { scratch.resumeWriter() }

        let writeOffsetFrames = Int(scratch.snapshotWriteOffset()) % framesPerFile
        let firstChunkFrames  = framesPerFile - writeOffsetFrames
        let secondChunkFrames = writeOffsetFrames
        let stamp = filenameTimestamp(firstPressTime)
        let nch = format.channelCount
        let sampleRate = format.sampleRate
        let scratchDir = scratch.directory

        let started = Date()

        var results: [ChannelResult] = Array(
            repeating: ChannelResult(peakDBFS: -.infinity, fileURL: nil, errorMessage: nil),
            count: nch)

        // Per-channel reads + peak compute + WAV write run in parallel. Each
        // iteration owns its own scratch fd, sample buffer, and output file —
        // no shared mutable state — and writes its result into a fixed index of
        // `results`, so concurrent writes don't collide.
        results.withUnsafeMutableBufferPointer { buf in
            let ptr = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: nch) { ch in
                ptr[ch] = processChannel(
                    ch: ch,
                    scratchDir: scratchDir,
                    framesPerFile: framesPerFile,
                    writeOffsetFrames: writeOffsetFrames,
                    bytesPerSample: bytesPerSample,
                    firstChunkFrames: firstChunkFrames,
                    secondChunkFrames: secondChunkFrames,
                    sampleRate: sampleRate,
                    timestamp: stamp,
                    outputRoot: outputRoot)
            }
        }

        var written: [URL] = []
        var skipped: [Int] = []
        var peaks: [Float] = []
        var errors: [(channel: Int, message: String)] = []
        peaks.reserveCapacity(nch)

        for (ch, r) in results.enumerated() {
            peaks.append(r.peakDBFS)
            let dbStr = r.peakDBFS.isFinite ? String(format: "%.1f dBFS", r.peakDBFS) : "-inf dBFS"

            if let err = r.errorMessage {
                log.error("ch\(ch + 1, privacy: .public): \(err, privacy: .public)")
                errors.append((channel: ch, message: err))
            } else if let url = r.fileURL {
                log.info("ch\(ch + 1, privacy: .public): \(dbStr, privacy: .public) → saved")
                written.append(url)
            } else {
                log.info("ch\(ch + 1, privacy: .public): \(dbStr, privacy: .public) → skipped")
                skipped.append(ch)
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        log.info("Extracted \(written.count, privacy: .public) ch, skipped \(skipped.count, privacy: .public) silent, errors \(errors.count, privacy: .public) in \(elapsed, format: .fixed(precision: 2), privacy: .public) s → \(outputRoot.path, privacy: .public)")

        return ExtractionResult(
            outputDirectory: outputRoot,
            writtenFiles: written,
            skippedSilentChannels: skipped,
            peaksDBFS: peaks,
            channelErrors: errors)
    }

    // MARK: - Per-channel work (runs on a concurrentPerform thread)

    private static func processChannel(
        ch: Int,
        scratchDir: URL,
        framesPerFile: Int,
        writeOffsetFrames: Int,
        bytesPerSample: Int,
        firstChunkFrames: Int,
        secondChunkFrames: Int,
        sampleRate: Double,
        timestamp: String,
        outputRoot: URL
    ) -> ChannelResult {
        do {
            let scratchFile = scratchDir.appendingPathComponent(String(format: "ch%02d.pcm", ch))
            let samples = try readChannelChronological(
                file: scratchFile,
                framesPerFile: framesPerFile,
                writeOffsetFrames: writeOffsetFrames,
                bytesPerSample: bytesPerSample,
                firstChunkFrames: firstChunkFrames,
                secondChunkFrames: secondChunkFrames)

            let peakLinear = WAVWriter.peakAmplitude(samples)
            let peakDB: Float = peakLinear > 0 ? 20 * log10f(peakLinear) : -.infinity

            if peakLinear >= silenceThresholdLinear {
                let outURL = outputRoot.appendingPathComponent(
                    String(format: "%@_ch%02d.wav", timestamp, ch + 1))
                try WAVWriter.writeFloat32(
                    url: outURL,
                    sampleRate: sampleRate,
                    channels: [samples])
                return ChannelResult(peakDBFS: peakDB, fileURL: outURL, errorMessage: nil)
            } else {
                return ChannelResult(peakDBFS: peakDB, fileURL: nil, errorMessage: nil)
            }
        } catch {
            return ChannelResult(peakDBFS: -.infinity, fileURL: nil, errorMessage: error.localizedDescription)
        }
    }

    private static func readChannelChronological(
        file: URL,
        framesPerFile: Int,
        writeOffsetFrames: Int,
        bytesPerSample: Int,
        firstChunkFrames: Int,
        secondChunkFrames: Int
    ) throws -> [Float] {
        let fd = file.path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            throw NSError(domain: "ScratchExtractor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "open(\(file.path)): \(err)"])
        }
        defer { close(fd) }

        var samples = [Float](repeating: 0, count: framesPerFile)

        try samples.withUnsafeMutableBufferPointer { bp in
            let basePtr = UnsafeMutableRawPointer(bp.baseAddress!)
            let firstByteOffset = off_t(writeOffsetFrames * bytesPerSample)
            let firstByteCount = firstChunkFrames * bytesPerSample
            try preadAll(fd: fd, dst: basePtr, count: firstByteCount, offset: firstByteOffset)

            if secondChunkFrames > 0 {
                let dst2 = basePtr.advanced(by: firstByteCount)
                let count2 = secondChunkFrames * bytesPerSample
                try preadAll(fd: fd, dst: dst2, count: count2, offset: 0)
            }
        }

        return samples
    }

    private static func preadAll(fd: Int32, dst: UnsafeMutableRawPointer, count: Int, offset: off_t) throws {
        var remaining = count
        var cursor = dst
        var off = offset
        while remaining > 0 {
            let n = pread(fd, cursor, remaining, off)
            if n <= 0 {
                let err = String(cString: strerror(errno))
                throw NSError(domain: "ScratchExtractor", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "pread short/error: \(err)"])
            }
            remaining -= n
            cursor = cursor.advanced(by: n)
            off += off_t(n)
        }
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}

// On capture trigger:
//   1. Pause the scratch writer so the per-channel files are stable while we read.
//   2. Snapshot the current circular write offset (oldest-frame position).
//   3. Group channels into output units — a marked stereo pair becomes one
//      2-channel WAV; everything else is a mono WAV.
//   4. For each unit in parallel: read its channel(s) chronologically, analyse
//      them, write a WAV if peak ≥ silence threshold.
//   5. Log peak dBFS for every unit (saved or skipped).
//   6. Resume the writer.
//
// The analysis in step 4 is the same `SignalAnalyzer` the review window uses.
// Running it here — where the samples are already in RAM — means a fresh capture
// can be auditioned without re-reading anything from disk.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "Extractor")

struct ExtractionResult {
    let outputDirectory: URL
    let writtenFiles: [URL]
    let skippedSilentChannels: [Int]
    let channelErrors: [(channel: Int, message: String)]
    /// Analysis for each written file. The samples are already in RAM here, so
    /// computing it now is nearly free and saves the review window a re-read.
    let stats: [URL: SignalStats]
}

private struct UnitResult {
    let channels: [Int]
    let stats: SignalStats?
    let fileURL: URL?
    let errorMessage: String?

    var peakDBFS: Float { stats?.peakDBFS ?? -.infinity }
}

enum ScratchExtractor {
    /// Anything with peak below this is skipped as silence.
    static let silenceThresholdDBFS: Float = -60.0
    static let silenceThresholdLinear: Float = pow(10.0, silenceThresholdDBFS / 20.0)

    /// - Parameter stereoPairLefts: 0-indexed left channels; each forms a stereo
    ///   unit with the channel immediately after it.
    /// - Parameter bpm: Current Ableton Link tempo, if joined. Drives the
    ///   `_<bpm>bpm_` filename segment and the BPM field in the WAV metadata.
    ///   Pass `nil` when no Link peer is present.
    /// - Parameter linkPlaying: Link transport state. Only meaningful when
    ///   `bpm != nil`.
    /// - Parameter appVersion: Used in the WAV ISFT chunk.
    static func extract(
        scratch: ScratchBuffer,
        firstPressTime: Date,
        outputRoot: URL,
        stereoPairLefts: Set<Int>,
        bpm: Double? = nil,
        linkPlaying: Bool = false,
        appVersion: String = "0.0.0"
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
        let stem = filenameStem(timestamp: firstPressTime, bpm: bpm)
        let nch = format.channelCount
        let sampleRate = format.sampleRate
        let scratchDir = scratch.directory
        let metadata = buildMetadata(
            timestamp: firstPressTime,
            bpm: bpm,
            linkPlaying: linkPlaying,
            appVersion: appVersion)

        // Group channels into mono / stereo output units.
        var units: [[Int]] = []
        var ch = 0
        while ch < nch {
            if stereoPairLefts.contains(ch), ch + 1 < nch {
                units.append([ch, ch + 1])
                ch += 2
            } else {
                units.append([ch])
                ch += 1
            }
        }

        let started = Date()

        var results = [UnitResult](
            repeating: UnitResult(channels: [], stats: nil, fileURL: nil, errorMessage: nil),
            count: units.count)

        results.withUnsafeMutableBufferPointer { buf in
            let ptr = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: units.count) { i in
                ptr[i] = processUnit(
                    channels: units[i],
                    scratchDir: scratchDir,
                    framesPerFile: framesPerFile,
                    writeOffsetFrames: writeOffsetFrames,
                    bytesPerSample: bytesPerSample,
                    firstChunkFrames: firstChunkFrames,
                    secondChunkFrames: secondChunkFrames,
                    sampleRate: sampleRate,
                    filenameStem: stem,
                    metadata: metadata,
                    outputRoot: outputRoot)
            }
        }

        var written: [URL] = []
        var skipped: [Int] = []
        var errors: [(channel: Int, message: String)] = []
        var stats: [URL: SignalStats] = [:]

        for r in results {
            let label = r.channels.map { String($0 + 1) }.joined(separator: "+")
            let dbStr = r.peakDBFS.isFinite ? String(format: "%.1f dBFS", r.peakDBFS) : "-inf dBFS"

            if let err = r.errorMessage {
                log.error("ch\(label, privacy: .public): \(err, privacy: .public)")
                errors.append((channel: r.channels.first ?? -1, message: err))
            } else if let url = r.fileURL {
                log.info("ch\(label, privacy: .public): \(dbStr, privacy: .public) → saved")
                written.append(url)
                if let s = r.stats { stats[url] = s }
            } else {
                log.info("ch\(label, privacy: .public): \(dbStr, privacy: .public) → skipped")
                skipped.append(contentsOf: r.channels)
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        log.info("Extracted \(written.count, privacy: .public) files, skipped \(skipped.count, privacy: .public) silent ch, errors \(errors.count, privacy: .public) in \(elapsed, format: .fixed(precision: 2), privacy: .public) s → \(outputRoot.path, privacy: .public)")

        return ExtractionResult(
            outputDirectory: outputRoot,
            writtenFiles: written,
            skippedSilentChannels: skipped,
            channelErrors: errors,
            stats: stats)
    }

    // MARK: - Per-unit work (runs on a concurrentPerform thread)

    private static func processUnit(
        channels: [Int],
        scratchDir: URL,
        framesPerFile: Int,
        writeOffsetFrames: Int,
        bytesPerSample: Int,
        firstChunkFrames: Int,
        secondChunkFrames: Int,
        sampleRate: Double,
        filenameStem: String,
        metadata: WAVMetadata,
        outputRoot: URL
    ) -> UnitResult {
        do {
            var perChannelSamples: [[Float]] = []
            var perChannelStats: [SignalStats] = []
            var unitPeak: Float = 0
            for ch in channels {
                let scratchFile = scratchDir.appendingPathComponent(String(format: "ch%02d.pcm", ch))
                let samples = try readChannelChronological(
                    file: scratchFile,
                    framesPerFile: framesPerFile,
                    writeOffsetFrames: writeOffsetFrames,
                    bytesPerSample: bytesPerSample,
                    firstChunkFrames: firstChunkFrames,
                    secondChunkFrames: secondChunkFrames)
                // One walk yields the peak the silence gate needs plus everything
                // the review window would otherwise have to re-read the file for.
                let stats = SignalAnalyzer.analyze(samples, sampleRate: sampleRate)
                perChannelStats.append(stats)
                unitPeak = max(unitPeak, stats.peak)
                perChannelSamples.append(samples)
            }

            let unitStats = SignalStats.merge(perChannelStats)

            // Keep the whole unit if any channel in it has signal.
            guard unitPeak >= silenceThresholdLinear else {
                return UnitResult(channels: channels, stats: unitStats, fileURL: nil, errorMessage: nil)
            }

            let suffix: String
            if channels.count == 2 {
                suffix = String(format: "ch%02d-%02d", channels[0] + 1, channels[1] + 1)
            } else {
                suffix = String(format: "ch%02d", channels[0] + 1)
            }
            let outURL = outputRoot.appendingPathComponent("\(filenameStem)_\(suffix).wav")
            try WAVWriter.writeFloat32(
                url: outURL,
                sampleRate: sampleRate,
                channels: perChannelSamples,
                metadata: metadata)
            return UnitResult(channels: channels, stats: unitStats, fileURL: outURL, errorMessage: nil)
        } catch {
            return UnitResult(channels: channels, stats: nil, fileURL: nil,
                              errorMessage: error.localizedDescription)
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

    /// Build the leading filename segment up to (but not including) the
    /// `_chNN[-MM].wav` portion. Includes the BPM segment when Link is active.
    private static func filenameStem(timestamp: Date, bpm: Double?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timeStr = formatter.string(from: timestamp)
        if let bpm, bpm > 0 {
            return "\(timeStr)_\(Int(bpm.rounded()))bpm"
        }
        return timeStr
    }

    private static func buildMetadata(
        timestamp: Date,
        bpm: Double?,
        linkPlaying: Bool,
        appVersion: String
    ) -> WAVMetadata {
        var parts: [String] = []
        if let bpm, bpm > 0 {
            parts.append("BPM=\(Int(bpm.rounded()))")
            parts.append("Link=\(linkPlaying ? "playing" : "stopped")")
        }
        parts.append("Source=seeed-recorder")
        return WAVMetadata(
            captureTimestamp: timestamp,
            comment: parts.joined(separator: "; "),
            software: "seeed-recorder/\(appVersion)")
    }
}

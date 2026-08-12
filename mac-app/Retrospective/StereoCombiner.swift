// Folds two mono captures into one interleaved stereo WAV.
//
// The extractor only pairs channels the user marked as stereo *before* the
// capture. Often you only realise two channels were a pair afterwards, while
// auditioning — this is the fix-up for that, and it produces a file identical in
// shape to one the extractor would have written, so Ableton and Resolve treat it
// the same as any other stereo capture.
//
// Reads stream chunk-by-chunk rather than decoding both files whole: a 30-minute
// pair would otherwise need ~690 MB of RAM to combine.
//
// Originals go to the Trash rather than being unlinked. These are takes that
// cannot be re-recorded, and a mistaken pairing has to be recoverable from
// Finder.

import Foundation
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "StereoCombiner")

enum StereoCombineError: LocalizedError {
    case notMono(String)
    case sampleRateMismatch(Double, Double)
    case sameFile
    case bufferAllocationFailed
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .notMono(let name):
            return "\(name) is not a mono file."
        case .sampleRateMismatch(let a, let b):
            return "Sample rates differ (\(Int(a)) Hz vs \(Int(b)) Hz)."
        case .sameFile:
            return "Pick two different channels."
        case .bufferAllocationFailed:
            return "Could not allocate a read buffer."
        case .destinationExists(let name):
            return "\(name) already exists."
        }
    }
}

enum StereoCombiner {

    /// Combines `left` and `right` into a new stereo file in the same folder.
    ///
    /// Channel order follows the channel numbers in the filenames — lower is
    /// left — so the result matches what the extractor would have produced had
    /// the pair been marked before the capture.
    ///
    /// - Returns: the URL of the file written.
    @discardableResult
    static func combine(
        left: CaptureFile,
        right: CaptureFile,
        session: CaptureSession,
        appVersion: String = "0.0.0",
        trashOriginals: Bool = true
    ) throws -> URL {
        guard left.url != right.url else { throw StereoCombineError.sameFile }

        // Order by channel number, not by selection order.
        let (a, b) = (left.channels.first ?? 0) <= (right.channels.first ?? 0)
            ? (left, right) : (right, left)

        let fileA = try AVAudioFile(forReading: a.url)
        let fileB = try AVAudioFile(forReading: b.url)

        guard fileA.processingFormat.channelCount == 1 else {
            throw StereoCombineError.notMono(a.url.lastPathComponent)
        }
        guard fileB.processingFormat.channelCount == 1 else {
            throw StereoCombineError.notMono(b.url.lastPathComponent)
        }
        let sampleRate = fileA.processingFormat.sampleRate
        guard sampleRate == fileB.processingFormat.sampleRate else {
            throw StereoCombineError.sampleRateMismatch(sampleRate, fileB.processingFormat.sampleRate)
        }

        // Captures from one press are the same length; clamp defensively so a
        // truncated file can't run the interleave off the end of the other.
        let frameCount = Int(min(fileA.length, fileB.length))

        let outURL = a.url.deletingLastPathComponent()
            .appendingPathComponent(outputFilename(for: session, channels: [
                a.channels.first ?? 0, b.channels.first ?? 0,
            ]))
        guard !FileManager.default.fileExists(atPath: outURL.path) else {
            throw StereoCombineError.destinationExists(outURL.lastPathComponent)
        }

        let metadata = WAVMetadata(
            captureTimestamp: session.timestamp,
            comment: session.bpm.map { "BPM=\($0); Source=seeed-recorder" } ?? "Source=seeed-recorder",
            software: "seeed-recorder/\(appVersion)")

        try writeInterleaved(
            a: fileA, b: fileB,
            frameCount: frameCount,
            sampleRate: sampleRate,
            metadata: metadata,
            to: outURL)

        log.info("Combined \(a.url.lastPathComponent, privacy: .public) + \(b.url.lastPathComponent, privacy: .public) → \(outURL.lastPathComponent, privacy: .public)")

        if trashOriginals {
            for url in [a.url, b.url] {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            }
        }
        return outURL
    }

    /// `2026-05-06_16-06-50[_120bpm][_name][_t3]_ch05-06.wav`, preserving
    /// whatever tags the session already carries.
    static func outputFilename(for session: CaptureSession, channels: [Int]) -> String {
        CaptureFilename(
            timestampText: session.id,
            timestamp: session.timestamp,
            bpm: session.bpm,
            name: session.name,
            take: session.take,
            channels: channels.sorted()
        ).formatted()
    }

    // MARK: - Streaming interleave

    private static func writeInterleaved(
        a: AVAudioFile,
        b: AVAudioFile,
        frameCount: Int,
        sampleRate: Double,
        metadata: WAVMetadata,
        to url: URL
    ) throws {
        let header = WAVWriter.buildHeader(
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            metadata: metadata)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var completed = false
        defer {
            try? handle.close()
            // Never leave a half-written stereo file looking like a real capture.
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        try handle.write(contentsOf: header)

        let chunkFrames: AVAudioFrameCount = 1 << 16     // 65536 frames ≈ 1.5 s @ 44.1 kHz
        guard let bufA = AVAudioPCMBuffer(pcmFormat: a.processingFormat, frameCapacity: chunkFrames),
              let bufB = AVAudioPCMBuffer(pcmFormat: b.processingFormat, frameCapacity: chunkFrames)
        else { throw StereoCombineError.bufferAllocationFailed }

        var interleaved = [Float](repeating: 0, count: Int(chunkFrames) * 2)
        var written = 0

        // Bounded by `frameCount` rather than by a short read: AVAudioFile.read
        // throws at EOF even after returning every frame (see AnalysisCache).
        while written < frameCount {
            let want = AVAudioFrameCount(min(Int(chunkFrames), frameCount - written))
            try a.read(into: bufA, frameCount: want)
            try b.read(into: bufB, frameCount: want)

            let frames = Int(min(bufA.frameLength, bufB.frameLength))
            if frames == 0 { break }
            guard let dataA = bufA.floatChannelData, let dataB = bufB.floatChannelData else { break }

            for i in 0..<frames {
                interleaved[i * 2]     = dataA[0][i]
                interleaved[i * 2 + 1] = dataB[0][i]
            }
            try interleaved.withUnsafeBufferPointer { bp in
                try handle.write(contentsOf: Data(bytes: bp.baseAddress!, count: frames * 2 * 4))
            }
            written += frames
        }

        completed = true
    }
}

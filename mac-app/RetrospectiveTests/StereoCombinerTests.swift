// Combining is the one review operation that writes a new audio file, and it
// runs on takes that cannot be re-recorded. The cases that matter: the channels
// land on the correct sides, the file is a well-formed WAV that AVFoundation can
// read back, and a mismatched pair is refused rather than silently mangled.
//
// Every test passes `trashOriginals: false` — a test suite must not put things
// in the user's Trash.

import XCTest
import AVFoundation
@testable import Retrospective

final class StereoCombinerTests: XCTestCase {

    private var dir: URL!
    private let sessionID = "2026-05-06_16-06-50"
    private let sampleRate: Double = 44_100

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CombinerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeMono(
        channel: Int,
        frames: Int = 4096,
        value: Float,
        rate: Double? = nil
    ) throws -> CaptureFile {
        let name = String(format: "%@_ch%02d.wav", sessionID, channel)
        let url = dir.appendingPathComponent(name)
        try WAVWriter.writeFloat32(
            url: url,
            sampleRate: rate ?? sampleRate,
            channels: [[Float](repeating: value, count: frames)])
        return CaptureFile(url: url, channels: [channel])
    }

    private func writeStereo(channels: [Int], frames: Int = 4096) throws -> CaptureFile {
        let name = String(format: "%@_ch%02d-%02d.wav", sessionID, channels[0], channels[1])
        let url = dir.appendingPathComponent(name)
        try WAVWriter.writeFloat32(
            url: url,
            sampleRate: sampleRate,
            channels: [[Float](repeating: 0.1, count: frames), [Float](repeating: 0.2, count: frames)])
        return CaptureFile(url: url, channels: channels)
    }

    private func session(files: [CaptureFile], bpm: Int? = nil, name: String? = nil, take: Int? = nil) -> CaptureSession {
        CaptureSession(
            id: sessionID,
            timestamp: CaptureFilename.dateFormatter.date(from: sessionID)!,
            bpm: bpm, name: name, take: take, files: files)
    }

    // MARK: - Output shape

    func testCombinesTwoMonosIntoOneStereoFile() throws {
        let left = try writeMono(channel: 5, value: 0.5)
        let right = try writeMono(channel: 6, value: -0.25)

        let out = try StereoCombiner.combine(
            left: left, right: right,
            session: session(files: [left, right]),
            trashOriginals: false)

        XCTAssertEqual(out.lastPathComponent, "2026-05-06_16-06-50_ch05-06.wav")

        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(file.processingFormat.sampleRate, sampleRate)
        XCTAssertEqual(file.length, 4096)
    }

    /// The whole point of pairing: the lower channel number must end up on the
    /// left, whichever order the user ticked them in.
    func testLowerChannelBecomesLeftRegardlessOfArgumentOrder() throws {
        let five = try writeMono(channel: 5, value: 0.5)
        let six = try writeMono(channel: 6, value: -0.25)

        // Deliberately passed the wrong way round.
        let out = try StereoCombiner.combine(
            left: six, right: five,
            session: session(files: [five, six]),
            trashOriginals: false)

        let file = try AVAudioFile(forReading: out)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        try file.read(into: buffer, frameCount: 4096)
        let data = try XCTUnwrap(buffer.floatChannelData)

        XCTAssertEqual(data[0][0], 0.5, accuracy: 1e-6, "ch05 must be left")
        XCTAssertEqual(data[1][0], -0.25, accuracy: 1e-6, "ch06 must be right")
        XCTAssertEqual(out.lastPathComponent, "2026-05-06_16-06-50_ch05-06.wav")
    }

    /// The interleave runs in chunks of 65536 frames; this crosses that boundary
    /// to catch an off-by-one in the streaming loop.
    func testContentIsCorrectAcrossChunkBoundaries() throws {
        let frames = 70_000
        let left = try writeMono(channel: 1, frames: frames, value: 0.75)
        let right = try writeMono(channel: 2, frames: frames, value: -0.75)

        let out = try StereoCombiner.combine(
            left: left, right: right,
            session: session(files: [left, right]),
            trashOriginals: false)

        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.length, AVAudioFramePosition(frames))

        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
        let data = try XCTUnwrap(buffer.floatChannelData)

        // Sample either side of the 65536-frame chunk seam.
        for i in [0, 65_535, 65_536, frames - 1] {
            XCTAssertEqual(data[0][i], 0.75, accuracy: 1e-6, "left at frame \(i)")
            XCTAssertEqual(data[1][i], -0.75, accuracy: 1e-6, "right at frame \(i)")
        }
    }

    func testPreservesSessionTagsInOutputName() throws {
        let left = try writeMono(channel: 7, value: 0.1)
        let right = try writeMono(channel: 8, value: 0.2)

        let out = try StereoCombiner.combine(
            left: left, right: right,
            session: session(files: [left, right], bpm: 120, name: "acid jam", take: 3),
            trashOriginals: false)

        XCTAssertEqual(out.lastPathComponent, "2026-05-06_16-06-50_120bpm_acid-jam_t3_ch07-08.wav")
    }

    /// Non-adjacent channels are allowed — you often only notice a pair while
    /// auditioning, and they need not be neighbours on the interface.
    func testAllowsNonAdjacentChannels() throws {
        let left = try writeMono(channel: 5, value: 0.3)
        let right = try writeMono(channel: 11, value: 0.4)

        let out = try StereoCombiner.combine(
            left: left, right: right,
            session: session(files: [left, right]),
            trashOriginals: false)

        XCTAssertEqual(out.lastPathComponent, "2026-05-06_16-06-50_ch05-11.wav")
        let reparsed = try XCTUnwrap(CaptureFilename.parse(out.lastPathComponent))
        XCTAssertEqual(reparsed.channels, [5, 11])
    }

    // MARK: - Refusals

    func testRefusesStereoInput() throws {
        let mono = try writeMono(channel: 5, value: 0.5)
        let stereo = try writeStereo(channels: [7, 8])

        XCTAssertThrowsError(try StereoCombiner.combine(
            left: mono, right: stereo,
            session: session(files: [mono, stereo]),
            trashOriginals: false))
    }

    func testRefusesSampleRateMismatch() throws {
        let a = try writeMono(channel: 5, value: 0.5)
        let b = try writeMono(channel: 6, value: 0.5, rate: 48_000)

        XCTAssertThrowsError(try StereoCombiner.combine(
            left: a, right: b,
            session: session(files: [a, b]),
            trashOriginals: false)) { error in
            guard case StereoCombineError.sampleRateMismatch = error else {
                return XCTFail("Expected sampleRateMismatch, got \(error)")
            }
        }
    }

    func testRefusesCombiningAFileWithItself() throws {
        let a = try writeMono(channel: 5, value: 0.5)

        XCTAssertThrowsError(try StereoCombiner.combine(
            left: a, right: a,
            session: session(files: [a]),
            trashOriginals: false)) { error in
            guard case StereoCombineError.sameFile = error else {
                return XCTFail("Expected sameFile, got \(error)")
            }
        }
    }

    func testRefusesToOverwriteAnExistingFile() throws {
        let left = try writeMono(channel: 5, value: 0.5)
        let right = try writeMono(channel: 6, value: -0.25)
        let existing = try writeStereo(channels: [5, 6])
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.url.path))

        XCTAssertThrowsError(try StereoCombiner.combine(
            left: left, right: right,
            session: session(files: [left, right]),
            trashOriginals: false)) { error in
            guard case StereoCombineError.destinationExists = error else {
                return XCTFail("Expected destinationExists, got \(error)")
            }
        }
    }

    /// A pair with differing lengths is clamped to the shorter, not run off the
    /// end of the buffer.
    func testClampsToShorterFile() throws {
        let left = try writeMono(channel: 5, frames: 4096, value: 0.5)
        let right = try writeMono(channel: 6, frames: 2048, value: -0.5)

        let out = try StereoCombiner.combine(
            left: left, right: right,
            session: session(files: [left, right]),
            trashOriginals: false)

        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.length, 2048)
    }

    // MARK: - Header integrity

    /// Our writer is hand-rolled; a wrong RIFF size makes files that some tools
    /// open and others reject.
    func testWrittenFileHasConsistentRIFFSize() throws {
        let left = try writeMono(channel: 5, frames: 1000, value: 0.5)
        let right = try writeMono(channel: 6, frames: 1000, value: -0.5)

        let out = try StereoCombiner.combine(
            left: left, right: right,
            session: session(files: [left, right]),
            trashOriginals: false)

        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(data.subdata(in: 8..<12), Data("WAVE".utf8))

        let riffSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), data.count - 8, "RIFF size must equal file length minus the RIFF header")
    }
}

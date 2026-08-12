// Tagging writes chunks other software has to parse, and rewrites files that
// cannot be re-recorded. The things worth pinning down: the bext struct is
// exactly the size the spec says, the audio survives a rewrite byte-for-byte,
// re-applying an unchanged tag is a no-op, and user text with XML punctuation
// does not produce a malformed iXML document.

import XCTest
import AVFoundation
@testable import Retrospective

final class TaggingTests: XCTestCase {

    private var dir: URL!
    private let sessionID = "2026-05-06_16-06-50"
    private let sampleRate: Double = 44_100

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TaggingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func writeCapture(channel: Int = 5, frames: Int = 4096, metadata: WAVMetadata? = nil) throws -> CaptureFile {
        let name = String(format: "%@_ch%02d.wav", sessionID, channel)
        let url = dir.appendingPathComponent(name)
        let samples = (0..<frames).map { sinf(Float($0) * 0.01) * 0.5 }
        try WAVWriter.writeFloat32(url: url, sampleRate: sampleRate, channels: [samples], metadata: metadata)
        return CaptureFile(url: url, channels: [channel])
    }

    private func session(_ files: [CaptureFile], bpm: Int? = nil) -> CaptureSession {
        CaptureSession(
            id: sessionID,
            timestamp: CaptureFilename.dateFormatter.date(from: sessionID)!,
            bpm: bpm, name: nil, take: nil, files: files)
    }

    private func chunk(_ id: String, in url: URL) throws -> WAVChunk? {
        try WAVReader.chunks(at: url).first { $0.id == id }
    }

    // MARK: - Chunk structure

    func testBextChunkIsExactlyTheSpecSize() throws {
        let file = try writeCapture(metadata: WAVMetadata(
            captureTimestamp: .now, comment: "c", software: "s", sessionName: "test"))

        let bext = try XCTUnwrap(try chunk("bext", in: file.url))
        XCTAssertEqual(bext.payloadSize, WAVWriter.bextChunkSize, "EBU Tech 3285 fixes this at 602 bytes")
    }

    func testChunkOrderPutsMetadataBeforeAudio() throws {
        let file = try writeCapture(metadata: WAVMetadata(
            captureTimestamp: .now, comment: "c", software: "s", sessionName: "test"))

        let ids = try WAVReader.chunks(at: file.url).map(\.id)
        XCTAssertEqual(ids, ["fmt ", "bext", "iXML", "LIST", "data"])
    }

    func testRIFFSizeMatchesFileLength() throws {
        let file = try writeCapture(metadata: WAVMetadata(
            captureTimestamp: .now, comment: "c", software: "s",
            sessionName: "a name long enough to matter", note: "and a note"))

        let data = try Data(contentsOf: file.url)
        let riffSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), data.count - 8)
    }

    func testFileStillDecodesAfterMetadataIsAdded() throws {
        let file = try writeCapture(metadata: WAVMetadata(
            captureTimestamp: .now, comment: "c", software: "s", sessionName: "test", take: 2))

        // The chunks sit between fmt and data; AVFoundation must skip them.
        let audio = try AVAudioFile(forReading: file.url)
        XCTAssertEqual(audio.length, 4096)
        XCTAssertEqual(audio.processingFormat.channelCount, 1)
    }

    // MARK: - Round trip

    func testTagsRoundTripThroughTheFile() throws {
        let file = try writeCapture()
        let tags = SessionTags(name: "acid jam", take: 3, note: "303 into ripples", goodTake: true)

        let newURL = try Retagger.apply(tags, to: file, in: session([file]))
        let read = try WAVReader.tags(at: newURL)

        XCTAssertEqual(read.sessionName, "acid jam")
        XCTAssertEqual(read.take, 3)
        XCTAssertEqual(read.note, "303 into ripples")
        XCTAssertTrue(read.goodTake)
    }

    func testRetagRenamesTheFile() throws {
        let file = try writeCapture(channel: 7)
        let tags = SessionTags(name: "acid jam", take: 3)

        let newURL = try Retagger.apply(tags, to: file, in: session([file]))

        XCTAssertEqual(newURL.lastPathComponent, "2026-05-06_16-06-50_acid-jam_t3_ch07.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path), "Old name should be gone")
    }

    /// Applying the same tags twice must not keep renaming or corrupt anything —
    /// the sanitised name has to survive the filename round trip.
    func testRetagIsIdempotent() throws {
        let file = try writeCapture()
        let tags = SessionTags(name: "acid jam", take: 3, note: "hello")

        let first = try Retagger.apply(tags, to: file, in: session([file]))
        let firstData = try Data(contentsOf: first)

        // Re-read tags and re-apply, as the UI would after a reload.
        let reread = try WAVReader.tags(at: first)
        let again = SessionTags(
            name: reread.sessionName, take: reread.take,
            note: reread.note, goodTake: reread.goodTake)
        let second = try Retagger.apply(
            again,
            to: CaptureFile(url: first, channels: [5]),
            in: session([CaptureFile(url: first, channels: [5])]))

        XCTAssertEqual(second, first, "Filename must be stable across repeated tagging")
        XCTAssertEqual(try Data(contentsOf: second), firstData, "Second pass must change nothing")
    }

    /// The whole point of the atomic rewrite: audio is copied, never re-encoded.
    func testAudioIsBitIdenticalAfterRetag() throws {
        let file = try writeCapture(frames: 20_000)

        let before = try WAVReader.chunks(at: file.url).first { $0.id == "data" }!
        let beforeAudio = try WAVReader.payload(of: before, at: file.url)

        let newURL = try Retagger.apply(
            SessionTags(name: "renamed", take: 9, note: "x", goodTake: true),
            to: file, in: session([file]))

        let after = try WAVReader.chunks(at: newURL).first { $0.id == "data" }!
        let afterAudio = try WAVReader.payload(of: after, at: newURL)

        XCTAssertEqual(afterAudio, beforeAudio, "Audio payload must survive untouched")
    }

    func testRetagPreservesExistingBPMInFilename() throws {
        let name = "\(sessionID)_120bpm_ch05.wav"
        let url = dir.appendingPathComponent(name)
        try WAVWriter.writeFloat32(url: url, sampleRate: sampleRate, channels: [[Float](repeating: 0.2, count: 512)])
        let file = CaptureFile(url: url, channels: [5])

        let newURL = try Retagger.apply(
            SessionTags(name: "jam", take: 1),
            to: file, in: session([file], bpm: 120))

        XCTAssertEqual(newURL.lastPathComponent, "2026-05-06_16-06-50_120bpm_jam_t1_ch05.wav")
    }

    // MARK: - Hostile input

    func testXMLPunctuationInTagsProducesValidDocument() throws {
        let file = try writeCapture()
        let nasty = "Bass & <Drums> \"quoted\" 'single'"

        let newURL = try Retagger.apply(
            SessionTags(name: nasty, take: 1, note: "a < b & c > d"),
            to: file, in: session([file]))

        let ixml = try XCTUnwrap(try chunk("iXML", in: newURL))
        let payload = try WAVReader.payload(of: ixml, at: newURL)

        // Must parse as real XML, not just look plausible.
        let parser = XMLParser(data: payload)
        XCTAssertTrue(parser.parse(), "iXML must be well-formed: \(parser.parserError?.localizedDescription ?? "")")

        let read = try WAVReader.tags(at: newURL)
        XCTAssertEqual(read.sessionName, nasty, "Escaped text must come back exactly")
        XCTAssertEqual(read.note, "a < b & c > d")
    }

    /// An overlong name has to survive three different limits: the fixed
    /// 256-byte bext Description, the 255-byte macOS filename, and iXML which
    /// has neither. Getting this wrong used to leave a file tagged but not
    /// renamed, because the rename ran after the rewrite and failed.
    func testOverlongNameDoesNotOverflowAnyLimit() throws {
        let file = try writeCapture()
        let long = String(repeating: "long name ", count: 60)   // 600 chars

        let newURL = try Retagger.apply(SessionTags(name: long, take: 1), to: file, in: session([file]))

        let bext = try XCTUnwrap(try chunk("bext", in: newURL))
        XCTAssertEqual(bext.payloadSize, WAVWriter.bextChunkSize)

        XCTAssertLessThan(newURL.lastPathComponent.utf8.count, 255, "Filename must fit macOS's limit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))

        // iXML is not fixed-width, so the full name survives there (bar the
        // surrounding whitespace both sides agree to strip).
        XCTAssertEqual(
            try WAVReader.tags(at: newURL).sessionName,
            long.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSurroundingWhitespaceIsStrippedConsistently() throws {
        let file = try writeCapture()

        let newURL = try Retagger.apply(
            SessionTags(name: "  acid jam  ", take: 1, note: "  a note  "),
            to: file, in: session([file]))

        let read = try WAVReader.tags(at: newURL)
        XCTAssertEqual(read.sessionName, "acid jam")
        XCTAssertEqual(read.note, "a note")
        XCTAssertEqual(newURL.lastPathComponent, "2026-05-06_16-06-50_acid-jam_t1_ch05.wav")
    }

    /// Truncation must not break idempotency: the long name comes back from
    /// iXML in full and has to truncate to the identical filename each time.
    func testOverlongNameStillRetagsIdempotently() throws {
        let file = try writeCapture()
        let long = String(repeating: "long name ", count: 60)

        let first = try Retagger.apply(SessionTags(name: long, take: 1), to: file, in: session([file]))
        let reread = try WAVReader.tags(at: first)
        let second = try Retagger.apply(
            SessionTags(name: reread.sessionName, take: reread.take),
            to: CaptureFile(url: first, channels: [5]),
            in: session([CaptureFile(url: first, channels: [5])]))

        XCTAssertEqual(second, first)
    }

    func testUntaggedFileReportsNoTags() throws {
        let file = try writeCapture()
        XCTAssertTrue(try WAVReader.tags(at: file.url).isEmpty)
    }

    func testReaderRejectsNonRIFF() throws {
        let url = dir.appendingPathComponent("junk.wav")
        try Data("this is not a wav file at all".utf8).write(to: url)
        XCTAssertThrowsError(try WAVReader.chunks(at: url))
    }

    /// A session note and a `<SPEED><NOTE>` both use the NOTE tag; the session
    /// one must win.
    func testSpeedNoteDoesNotShadowSessionNote() throws {
        let file = try writeCapture(metadata: WAVMetadata(
            captureTimestamp: .now, comment: "c", software: "s",
            sessionName: "jam", note: "the real note", bpm: 120))

        XCTAssertEqual(try WAVReader.tags(at: file.url).note, "the real note")
    }
}

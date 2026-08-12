// Session grouping is derived entirely from filenames, so a parser regression
// silently splits one capture into several sessions (or merges two). These also
// guard back-compatibility: captures written before the review feature existed
// have no name or take segment and must still parse.

import XCTest
@testable import Retrospective

final class CaptureFilenameTests: XCTestCase {

    func testParsesMonoWithBPM() throws {
        let parsed = try XCTUnwrap(CaptureFilename.parse("2026-08-11_14-23-05_120bpm_ch01.wav"))

        XCTAssertEqual(parsed.timestampText, "2026-08-11_14-23-05")
        XCTAssertEqual(parsed.bpm, 120)
        XCTAssertEqual(parsed.channels, [1])
        XCTAssertNil(parsed.name)
        XCTAssertNil(parsed.take)
    }

    func testParsesStereoPairWithoutBPM() throws {
        let parsed = try XCTUnwrap(CaptureFilename.parse("2026-08-11_14-23-05_ch03-04.wav"))

        XCTAssertEqual(parsed.channels, [3, 4])
        XCTAssertNil(parsed.bpm)
    }

    func testParsesTaggedFilename() throws {
        let parsed = try XCTUnwrap(CaptureFilename.parse("2026-08-11_14-23-05_120bpm_acid-jam_t3_ch07.wav"))

        XCTAssertEqual(parsed.bpm, 120)
        XCTAssertEqual(parsed.name, "acid-jam")
        XCTAssertEqual(parsed.take, 3)
        XCTAssertEqual(parsed.channels, [7])
    }

    /// Session identity is the timestamp, so a tagged and an untagged file from
    /// the same press must land in the same session.
    func testTaggingDoesNotChangeSessionIdentity() throws {
        let untagged = try XCTUnwrap(CaptureFilename.parse("2026-08-11_14-23-05_120bpm_ch01.wav"))
        let tagged = try XCTUnwrap(CaptureFilename.parse("2026-08-11_14-23-05_120bpm_acid-jam_t3_ch02.wav"))

        XCTAssertEqual(untagged.timestampText, tagged.timestampText)
    }

    func testRoundTripsThroughFormatted() throws {
        let names = [
            "2026-08-11_14-23-05_120bpm_ch01.wav",
            "2026-08-11_14-23-05_ch03-04.wav",
            "2026-08-11_14-23-05_120bpm_acid-jam_t3_ch07.wav",
            "2026-01-02_09-05-00_ch16.wav",
        ]
        for name in names {
            let parsed = try XCTUnwrap(CaptureFilename.parse(name), name)
            XCTAssertEqual(parsed.formatted(), name)
        }
    }

    func testParsesTimestamp() throws {
        let parsed = try XCTUnwrap(CaptureFilename.parse("2026-08-11_14-23-05_ch01.wav"))
        let expected = CaptureFilename.dateFormatter.date(from: "2026-08-11_14-23-05")
        XCTAssertEqual(parsed.timestamp, expected)
    }

    func testRejectsNonCaptures() {
        let rejects = [
            "notes.txt",
            "randomfile.wav",
            "2026-08-11_14-23-05.wav",          // no channel segment
            "2026-08-11_ch01.wav",              // truncated timestamp
            "banana_ch01.wav",
            "2026-13-45_99-99-99_ch01.wav",     // not a real date
        ]
        for name in rejects {
            XCTAssertNil(CaptureFilename.parse(name), "Should not parse: \(name)")
        }
    }

    // MARK: - Sanitising

    func testSanitiseMakesNamesFilenameSafe() {
        // Underscore is the field separator, so it must never survive a name.
        XCTAssertEqual(CaptureFilename.sanitize("acid jam"), "acid-jam")
        XCTAssertEqual(CaptureFilename.sanitize("acid_jam"), "acid-jam")
        XCTAssertEqual(CaptureFilename.sanitize("take 3/4"), "take-3-4")
        XCTAssertEqual(CaptureFilename.sanitize("  spaced  out  "), "spaced-out")
        XCTAssertEqual(CaptureFilename.sanitize("a::b"), "a-b")
    }

    /// A name typed with spaces must survive being written to a filename and
    /// read back, or a retag would rename the file every time it is applied.
    func testSanitisedNameSurvivesRoundTrip() throws {
        var parsed = try XCTUnwrap(CaptureFilename.parse("2026-08-11_14-23-05_ch01.wav"))
        parsed.name = "acid jam"
        parsed.take = 2

        let filename = parsed.formatted()
        XCTAssertEqual(filename, "2026-08-11_14-23-05_acid-jam_t2_ch01.wav")

        let reparsed = try XCTUnwrap(CaptureFilename.parse(filename))
        XCTAssertEqual(reparsed.name, "acid-jam")
        XCTAssertEqual(reparsed.take, 2)
        XCTAssertEqual(reparsed.formatted(), filename, "Re-applying a tag must be idempotent")
    }
}

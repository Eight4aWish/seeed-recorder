// Grouping captures into sittings. The threshold and the shapes tested here come
// from the real library: within a sitting, gaps topped out at 20.4 minutes; the
// next gap up was 52.9 minutes. 30 minutes sits in the empty space between.

import XCTest
@testable import Retrospective

final class CaptureGroupTests: XCTestCase {

    /// Builds sessions from "HH-MM" times on a fixed day, newest first — the
    /// order `SessionLibrary.scan` produces.
    private func sessions(_ times: [String], day: String = "2026-06-05") -> [CaptureSession] {
        times.map { time -> CaptureSession in
            let id = "\(day)_\(time)-00"
            return CaptureSession(
                id: id,
                timestamp: CaptureFilename.dateFormatter.date(from: id)!,
                bpm: nil, name: nil, take: nil,
                files: [CaptureFile(url: URL(fileURLWithPath: "/tmp/\(id)_ch01.wav"), channels: [1])])
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    func testRapidFireCapturesFormOneGroup() {
        let groups = SessionLibrary.group(sessions(["11-48", "11-54", "11-56", "12-14", "12-16"]), gapMinutes: 30)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].captures.count, 5)
    }

    /// The real 5 June shape: three sittings in one day, separated by 106 and 53
    /// minute gaps.
    func testSameDaySittingsSplitOnLongGaps() {
        let groups = SessionLibrary.group(
            sessions(["11-48", "11-54", "12-16", "14-02", "14-03", "14-56", "15-04", "15-09"]),
            gapMinutes: 30)

        XCTAssertEqual(groups.count, 3, "Morning, early afternoon and late afternoon are separate sittings")
        // Newest group first.
        XCTAssertEqual(groups[0].captures.count, 3)   // 14:56, 15:04, 15:09
        XCTAssertEqual(groups[1].captures.count, 2)   // 14:02, 14:03
        XCTAssertEqual(groups[2].captures.count, 3)   // 11:48, 11:54, 12:16
    }

    /// A 20-minute gap is within a sitting; the next real gap up is 53 minutes.
    /// The threshold has to keep those apart.
    func testTwentyMinuteGapStaysTogetherAndFiftyThreeSplits() {
        let together = SessionLibrary.group(sessions(["10-00", "10-20"]), gapMinutes: 30)
        XCTAssertEqual(together.count, 1, "20 min is within a sitting")

        let apart = SessionLibrary.group(sessions(["10-00", "10-53"]), gapMinutes: 30)
        XCTAssertEqual(apart.count, 2, "53 min is a new sitting")
    }

    func testCapturesOnDifferentDaysNeverGroup() {
        var all = sessions(["16-05"], day: "2026-07-18")
        all += sessions(["09-55"], day: "2026-07-19")
        let groups = SessionLibrary.group(all.sorted { $0.timestamp > $1.timestamp }, gapMinutes: 30)

        XCTAssertEqual(groups.count, 2)
    }

    func testGroupsAreNewestFirstAndCapturesWithinThemToo() {
        let groups = SessionLibrary.group(sessions(["09-00", "09-05", "14-00", "14-05"]), gapMinutes: 30)

        XCTAssertEqual(groups.count, 2)
        XCTAssertGreaterThan(groups[0].end, groups[1].end, "Newest sitting first")
        XCTAssertGreaterThan(groups[0].captures[0].timestamp, groups[0].captures[1].timestamp)
        // start/end span the sitting in chronological order.
        XCTAssertLessThan(groups[0].start, groups[0].end)
    }

    func testThresholdIsHonoured() {
        let times = ["10-00", "10-25"]
        XCTAssertEqual(SessionLibrary.group(sessions(times), gapMinutes: 30).count, 1)
        XCTAssertEqual(SessionLibrary.group(sessions(times), gapMinutes: 15).count, 2)
    }

    func testEmptyAndSingleInputs() {
        XCTAssertTrue(SessionLibrary.group([], gapMinutes: 30).isEmpty)
        XCTAssertEqual(SessionLibrary.group(sessions(["10-00"]), gapMinutes: 30).count, 1)
    }

    func testSubtitleDescribesTheSpan() {
        let groups = SessionLibrary.group(sessions(["11-48", "12-16"]), gapMinutes: 30)
        let subtitle = groups[0].subtitle

        XCTAssertTrue(subtitle.contains("2 captures"), subtitle)
        XCTAssertTrue(subtitle.contains("–"), "Multi-capture sittings show a time range: \(subtitle)")

        let single = SessionLibrary.group(sessions(["11-48"]), gapMinutes: 30)[0].subtitle
        XCTAssertTrue(single.contains("1 capture"), single)
        XCTAssertFalse(single.contains("–"), "A single capture needs no range: \(single)")
    }
}

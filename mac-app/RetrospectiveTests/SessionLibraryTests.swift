// Grouping is derived from filenames alone, and the captures folder is a shared
// space — Ableton drops `.wav.asd` analysis sidecars right next to the captures
// once the files have been imported. A scan that mistook those for audio would
// double every channel in the session list.

import XCTest
@testable import Retrospective

final class SessionLibraryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RetrospectiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: root.appendingPathComponent(name))
    }

    func testGroupsFilesByCaptureTimestamp() async throws {
        try touch("2026-05-06_16-06-50_ch05.wav")
        try touch("2026-05-06_16-06-50_ch06.wav")
        try touch("2026-05-06_16-06-50_ch13-14.wav")
        try touch("2026-05-06_16-08-19_ch05.wav")
        try touch("2026-05-06_16-08-19_ch06.wav")

        let sessions = await SessionLibrary.scan(root: root)

        XCTAssertEqual(sessions.count, 2)
        // Newest first.
        XCTAssertEqual(sessions[0].id, "2026-05-06_16-08-19")
        XCTAssertEqual(sessions[0].files.count, 2)
        XCTAssertEqual(sessions[1].id, "2026-05-06_16-06-50")
        XCTAssertEqual(sessions[1].files.count, 3)
    }

    /// Ableton writes these after importing a capture. They must not appear as
    /// extra channels.
    func testIgnoresAbletonSidecarFiles() async throws {
        try touch("2026-05-07_09-19-26_ch05.wav")
        try touch("2026-05-07_09-19-26_ch05.wav.asd")
        try touch("2026-05-07_09-19-26_ch06.wav")
        try touch("2026-05-07_09-19-26_ch06.wav.asd")

        let sessions = await SessionLibrary.scan(root: root)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].files.count, 2, "Sidecars must not be counted as channels")
        XCTAssertTrue(sessions[0].files.allSatisfy { $0.url.pathExtension == "wav" })
    }

    func testIgnoresUnrelatedFiles() async throws {
        try touch("2026-05-07_09-19-26_ch05.wav")
        try touch("notes.txt")
        try touch("bounce.wav")
        try touch(".DS_Store")

        let sessions = await SessionLibrary.scan(root: root)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].files.count, 1)
    }

    func testChannelsSortIntoNumericOrder() async throws {
        for name in ["_ch11", "_ch05", "_ch18", "_ch07-08"] {
            try touch("2026-07-18_16-05-15\(name).wav")
        }

        let sessions = await SessionLibrary.scan(root: root)
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(session.files.map(\.channelLabel), ["ch05", "ch07-08", "ch11", "ch18"])
    }

    func testStereoPairIsOneFileNotTwo() async throws {
        try touch("2026-06-05_15-09-28_ch01-02.wav")

        let sessions = await SessionLibrary.scan(root: root)
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(session.files.count, 1)
        XCTAssertTrue(session.files[0].isStereo)
        XCTAssertEqual(session.files[0].channels, [1, 2])
    }

    func testEmptyFolderYieldsNoSessions() async throws {
        let sessions = await SessionLibrary.scan(root: root)
        XCTAssertTrue(sessions.isEmpty)
    }
}

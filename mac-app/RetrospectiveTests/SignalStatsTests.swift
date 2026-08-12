// The junk heuristic is the part of this feature that can be wrong in a way
// nobody notices until a take has been thrown away, so it gets pinned down here
// against synthesised signals with known character.
//
// The load-bearing case is `testKickPatternIsNotJunk`. A sparse rhythm has the
// same low duty cycle and high crest factor as a channel full of stray clicks —
// event count is the only thing separating them, and if that clause ever breaks
// the detector starts flagging real music.

import XCTest
@testable import Retrospective

final class SignalStatsTests: XCTestCase {

    private let sampleRate: Double = 48_000

    // MARK: - Generators

    /// Constant-amplitude sine.
    private func tone(frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { i in
            amplitude * sinf(Float(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    private func noise(amplitude: Float, seconds: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        let count = Int(sampleRate * seconds)
        return (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &rng) }
    }

    /// `count` single-sample impulses in an otherwise silent buffer.
    private func clicks(count: Int, amplitude: Float, seconds: Double) -> [Float] {
        let total = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<count {
            let position = total * (i + 1) / (count + 2)
            samples[position] = amplitude
        }
        return samples
    }

    /// Decaying sine bursts at a fixed tempo — a kick pattern.
    private func kickPattern(bpm: Double, seconds: Double) -> [Float] {
        let total = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: total)
        let period = Int(sampleRate * 60.0 / bpm)
        let burst = Int(sampleRate * 0.12)
        let tau: Float = 0.03

        var start = 0
        while start < total {
            for i in 0..<burst where start + i < total {
                let t = Float(i) / Float(sampleRate)
                let envelope = expf(-t / tau)
                samples[start + i] = 0.8 * envelope * sinf(2 * .pi * 60 * t)
            }
            start += period
        }
        return samples
    }

    // MARK: - Real audio must not flag

    func testToneIsNotJunk() {
        let stats = SignalAnalyzer.analyze(tone(frequency: 1000, amplitude: 0.5, seconds: 5), sampleRate: sampleRate)

        XCTAssertEqual(stats.peakDBFS, -6.02, accuracy: 0.1)
        // A sine's peak-to-RMS is √2, i.e. 3.01 dB.
        XCTAssertEqual(stats.crestDB, 3.01, accuracy: 0.1)
        XCTAssertEqual(stats.activeFraction, 1.0, accuracy: 0.01)
        XCTAssertTrue(stats.junkReasons().isEmpty, "A steady tone must never be junk")
    }

    func testNoiseIsNotJunk() {
        let stats = SignalAnalyzer.analyze(noise(amplitude: 0.4, seconds: 5), sampleRate: sampleRate)

        XCTAssertGreaterThan(stats.activeFraction, 0.9)
        XCTAssertTrue(stats.junkReasons().isEmpty, "Broadband noise must never be junk")
    }

    /// The case the whole heuristic is built around: sparse music that a
    /// duty-cycle-only detector would throw away.
    func testKickPatternIsNotJunk() {
        let stats = SignalAnalyzer.analyze(kickPattern(bpm: 120, seconds: 60), sampleRate: sampleRate)

        // 120 BPM over 60 s is 120 hits.
        XCTAssertGreaterThan(stats.eventCount, 100, "Expected roughly one event per beat")
        XCTAssertGreaterThan(
            stats.eventCount, JunkThresholds.default.maxEventCount,
            "Event count is the clause that saves sparse rhythms — it must clear the threshold")
        XCTAssertTrue(
            stats.junkReasons().isEmpty,
            "A sparse kick pattern is music, not spikes (crest \(stats.crestDB), active \(stats.activeFraction))")
    }

    /// Regression guard from calibration against 267 real captures.
    ///
    /// One of them was a genuine take where the player only got going near the
    /// end — 7.6 s of music inside a 120 s window. Under the original
    /// fraction-based rule it cleared junk detection by 6.37% vs a 2% threshold,
    /// meaning a slightly shorter take would have been flagged as junk. Absolute
    /// active time is what fixed it, and this test is what stops it regressing.
    func testShortRealTakeInALongWindowIsNotJunk() {
        let sampleCount = Int(sampleRate * 120)
        var samples = [Float](repeating: 0, count: sampleCount)
        let music = tone(frequency: 220, amplitude: 0.6, seconds: 2.5)
        // Drop it near the end, the way a retrospective capture actually lands.
        let start = sampleCount - music.count - Int(sampleRate)
        for (i, s) in music.enumerated() { samples[start + i] = s }

        let stats = SignalAnalyzer.analyze(samples, sampleRate: sampleRate)

        XCTAssertEqual(stats.activeSeconds, 2.5, accuracy: 0.1)
        XCTAssertLessThan(stats.activeFraction, 0.03, "This is exactly the case a fractional rule got wrong")
        XCTAssertTrue(
            stats.junkReasons().isEmpty,
            "2.5 s of real music must survive, however long the surrounding window")
    }

    // MARK: - Junk must flag

    func testIsolatedClicksAreJunk() {
        let stats = SignalAnalyzer.analyze(clicks(count: 3, amplitude: 0.5, seconds: 60), sampleRate: sampleRate)

        XCTAssertEqual(stats.eventCount, 3)
        XCTAssertGreaterThan(stats.crestDB, 40)
        XCTAssertEqual(stats.junkReasons(), [.sparseSpikes])

        // Calibration showed real stray clicks totalling 12–36 ms of activity
        // against a 250 ms threshold. Synthesised impulses must land in the same
        // regime, or this test is not exercising the real decision boundary.
        XCTAssertLessThan(stats.activeSeconds, 0.1)
    }

    func testDCOffsetIsJunk() {
        let stats = SignalAnalyzer.analyze([Float](repeating: 0.5, count: 48_000), sampleRate: sampleRate)

        XCTAssertEqual(stats.dcOffset, 0.5, accuracy: 0.001)
        XCTAssertEqual(stats.crestDB, 0, accuracy: 0.01)
        XCTAssertEqual(stats.junkReasons(), [.dcOffset])
    }

    func testSilenceIsNotFlaggedAsJunk() {
        // Digital silence is handled by the extractor's −60 dBFS gate before it
        // ever reaches the junk rules; the rules themselves must stay quiet.
        let stats = SignalAnalyzer.analyze([Float](repeating: 0, count: 48_000), sampleRate: sampleRate)

        XCTAssertEqual(stats.eventCount, 0)
        XCTAssertTrue(stats.junkReasons().isEmpty)
    }

    // MARK: - Transients

    func testTransientPositionsTrackTheClicks() {
        let seconds = 60.0
        let stats = SignalAnalyzer.analyze(clicks(count: 3, amplitude: 0.5, seconds: seconds), sampleRate: sampleRate)

        XCTAssertEqual(stats.transientFrames.count, 3)
        // Generator places clicks at 1/5, 2/5 and 3/5 of the buffer.
        let total = Int(sampleRate * seconds)
        let expected = [total / 5, total * 2 / 5, total * 3 / 5]
        let windowFrames = Int(sampleRate * SignalAnalyzer.windowSeconds)
        for (actual, want) in zip(stats.transientFrames, expected) {
            XCTAssertLessThan(abs(actual - want), windowFrames * 2,
                              "Transient should land within a window of the click")
        }
    }

    // MARK: - Incremental == one-shot

    /// The extractor feeds the whole channel at once while the review window
    /// streams it in chunks. Both paths must produce the same verdict.
    func testChunkedAnalysisMatchesOneShot() {
        let samples = kickPattern(bpm: 120, seconds: 10)
        let oneShot = SignalAnalyzer.analyze(samples, sampleRate: sampleRate)

        var chunked = SignalAnalyzer(totalFrames: samples.count, sampleRate: sampleRate)
        var offset = 0
        let chunk = 7919      // deliberately not a window or bucket multiple
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            samples[offset..<end].withUnsafeBufferPointer { chunked.consume($0) }
            offset = end
        }
        let streamed = chunked.finalize()

        XCTAssertEqual(streamed.frameCount, oneShot.frameCount)
        XCTAssertEqual(streamed.peak, oneShot.peak, accuracy: 1e-6)
        XCTAssertEqual(streamed.rms, oneShot.rms, accuracy: 1e-6)
        XCTAssertEqual(streamed.eventCount, oneShot.eventCount)
        XCTAssertEqual(streamed.activeFraction, oneShot.activeFraction, accuracy: 1e-6)
        XCTAssertEqual(streamed.junkReasons(), oneShot.junkReasons())
    }

    // MARK: - Merge

    func testStereoMergeKeepsPairWhenOneSideHasSignal() {
        let live = SignalAnalyzer.analyze(tone(frequency: 440, amplitude: 0.5, seconds: 5), sampleRate: sampleRate)
        let dead = SignalAnalyzer.analyze(clicks(count: 2, amplitude: 0.5, seconds: 5), sampleRate: sampleRate)

        let merged = SignalStats.merge([dead, live])
        XCTAssertNotNil(merged)
        XCTAssertTrue(merged!.junkReasons().isEmpty,
                      "A pair is only junk when both sides are")
    }

    // MARK: - Envelope packing

    func testEnvelopeSurvivesCodableRoundTrip() throws {
        let original = WaveformEnvelope(
            minValues: [-1.0, -0.5, 0, -0.25],
            maxValues: [1.0, 0.5, 0, 0.75])

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(
            WaveformEnvelope.self, from: try encoder.encode(original))

        XCTAssertEqual(decoded.bucketCount, original.bucketCount)
        for i in 0..<original.bucketCount {
            XCTAssertEqual(decoded.minValues[i], original.minValues[i], accuracy: 0.001)
            XCTAssertEqual(decoded.maxValues[i], original.maxValues[i], accuracy: 0.001)
        }
    }

    /// Capture is float32 and can exceed ±1.0 — quantisation must not clip it.
    func testEnvelopeHandlesOverUnitySamples() throws {
        let original = WaveformEnvelope(minValues: [-2.5], maxValues: [1.8])

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(
            WaveformEnvelope.self, from: try encoder.encode(original))

        XCTAssertEqual(decoded.minValues[0], -2.5, accuracy: 0.01)
        XCTAssertEqual(decoded.maxValues[0], 1.8, accuracy: 0.01)
    }
}

// Single-pass signal analysis for captured channels.
//
// Produces everything the review window needs from one walk over the samples:
//   - level metrics (peak, RMS, crest, DC offset) for the junk verdict
//   - a windowed activity profile (active fraction, event count, noise floor)
//   - a decimated min/max envelope for waveform drawing
//   - transient frame positions so audition can jump straight to the sound
//
// Why crest + activity + event count rather than just peak: the existing
// −60 dBFS peak gate in ScratchExtractor only catches dead channels. A channel
// carrying three clicks from a half-seated patch cable has a *loud* peak and no
// content. Crest factor and duty cycle catch that — but so would a sparse kick
// pattern, which is real music. Event count is what separates them: a handful
// of isolated spikes is junk, a hundred and twenty transients is a rhythm.
//
// The `noiseFloorDBFS` clause guards the remaining false positive: a quiet drone
// with one loud pop has a huge crest and a low duty cycle, but it is not junk
// because there is continuous signal between the spikes.

import Foundation

// MARK: - Thresholds

/// Junk-detection tuning. Surfaced in Settings so it can be calibrated against a
/// real rig without a rebuild — the defaults are reasoned, not measured.
struct JunkThresholds: Codable, Sendable, Equatable {
    /// Sparse-spike rule: all four clauses must hold.
    ///
    /// The gate is *absolute* active time, not a fraction of the capture.
    /// Measured against 267 real captures, stray clicks total 12–36 ms of
    /// activity while the shortest genuine take ran 7.6 s — two orders of
    /// magnitude of daylight, and 0.25 s sits in the middle of it. A fractional
    /// threshold would instead scale with the lookback setting, so the same
    /// two-second take would pass at a 60 s lookback and flag at 30 minutes.
    var maxActiveSeconds: Double = 0.25
    /// Kept as a second, conservative guard. Sustained audio reports a single
    /// event (it never falls back below the release gate), so this clause only
    /// bites on genuinely intermittent material.
    var maxEventCount: Int = 8
    var minCrestDB: Float = 24
    /// Level between the spikes must be essentially digital silence. Without
    /// this a quiet drone punctuated by one pop would flag.
    var maxNoiseFloorDBFS: Float = -60

    /// DC / CV rule: a near-constant signal is not audio.
    var maxDCCrestDB: Float = 1.5
    var minDCOffset: Float = 0.05

    static let `default` = JunkThresholds()

    // UserDefaults keys, shared by the review window and the Settings pane so
    // adjusting a threshold in one is reflected in the other immediately.
    static let activeSecondsKey = "junk.maxActiveSeconds"
    static let eventCountKey    = "junk.maxEventCount"
    static let crestKey         = "junk.minCrestDB"
    static let noiseFloorKey    = "junk.maxNoiseFloorDBFS"
}

enum JunkReason: String, Codable, Sendable, CaseIterable {
    case sparseSpikes
    case dcOffset

    var label: String {
        switch self {
        case .sparseSpikes: return "occasional spikes"
        case .dcOffset:     return "DC / not audio"
        }
    }
}

// MARK: - Envelope

/// Decimated min/max pairs for waveform drawing. One pair per horizontal bucket.
///
/// Codable is hand-rolled to pack the pairs into scaled Int16 rather than a
/// list of reals. A 2000-bucket envelope is 8 KB packed against ~32 KB as plist
/// reals, which matters because every captured file gets one in the cache.
struct WaveformEnvelope: Sendable {
    var minValues: [Float]
    var maxValues: [Float]

    var bucketCount: Int { minValues.count }

    static let empty = WaveformEnvelope(minValues: [], maxValues: [])

    /// Union of two envelopes with the same bucket count — used to fold a stereo
    /// pair's channels into a single drawable shape.
    func merged(with other: WaveformEnvelope) -> WaveformEnvelope {
        guard bucketCount == other.bucketCount else { return self }
        return WaveformEnvelope(
            minValues: zip(minValues, other.minValues).map(Swift.min),
            maxValues: zip(maxValues, other.maxValues).map(Swift.max))
    }
}

extension WaveformEnvelope: Codable {
    private enum CodingKeys: String, CodingKey { case scale, packed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let scale = try c.decode(Float.self, forKey: .scale)
        let packed = try c.decode(Data.self, forKey: .packed)

        let pairs = packed.count / 4        // two Int16 per bucket
        var mins = [Float](repeating: 0, count: pairs)
        var maxes = [Float](repeating: 0, count: pairs)
        packed.withUnsafeBytes { raw in
            for i in 0..<pairs {
                let lo = raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self)
                let hi = raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self)
                mins[i] = Float(lo) / 32767 * scale
                maxes[i] = Float(hi) / 32767 * scale
            }
        }
        self.minValues = mins
        self.maxValues = maxes
    }

    func encode(to encoder: Encoder) throws {
        // Capture is float32 and can exceed ±1.0, so normalise before quantising.
        let extent = max(
            minValues.map(abs).max() ?? 0,
            maxValues.map(abs).max() ?? 0)
        let scale = extent > 0 ? extent : 1

        var packed = Data(capacity: bucketCount * 4)
        for i in 0..<bucketCount {
            var lo = Int16((minValues[i] / scale * 32767).rounded())
            var hi = Int16((maxValues[i] / scale * 32767).rounded())
            withUnsafeBytes(of: &lo) { packed.append(contentsOf: $0) }
            withUnsafeBytes(of: &hi) { packed.append(contentsOf: $0) }
        }

        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scale, forKey: .scale)
        try c.encode(packed, forKey: .packed)
    }
}

// MARK: - Stats

struct SignalStats: Codable, Sendable {
    var frameCount: Int
    var sampleRate: Double

    /// Linear amplitudes; use the dBFS accessors for display.
    var peak: Float
    var rms: Float
    /// Mean sample value. A patched CV line sits far from zero.
    var dcOffset: Float

    /// Fraction of analysis windows above the activity gate, 0...1.
    var activeFraction: Float
    /// Rising edges into the gate — transient count over the whole capture.
    var eventCount: Int
    /// Median window level. What sits *between* the events.
    var noiseFloor: Float

    /// Frame positions of detected transients, capped at `maxTransients`.
    var transientFrames: [Int]
    var envelope: WaveformEnvelope

    // MARK: Derived

    var peakDBFS: Float { SignalStats.dbfs(peak) }
    var rmsDBFS: Float { SignalStats.dbfs(rms) }
    var noiseFloorDBFS: Float { SignalStats.dbfs(noiseFloor) }

    /// Peak-to-RMS in dB. Real audio sits around 8–20; isolated spikes 25–60;
    /// a DC level under 2.
    var crestDB: Float {
        guard peak > 0, rms > 0 else { return 0 }
        return peakDBFS - rmsDBFS
    }

    var duration: TimeInterval {
        sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }

    /// Wall-clock time this channel actually carried signal. The decision
    /// variable for the sparse-spike rule — see `JunkThresholds`.
    var activeSeconds: TimeInterval {
        duration * Double(activeFraction)
    }

    static func dbfs(_ linear: Float) -> Float {
        linear > 0 ? 20 * log10f(linear) : -.infinity
    }

    // MARK: Verdict

    /// Empty when the channel looks like real audio.
    func junkReasons(_ t: JunkThresholds = .default) -> [JunkReason] {
        var reasons: [JunkReason] = []

        if activeSeconds < t.maxActiveSeconds,
           eventCount <= t.maxEventCount,
           crestDB > t.minCrestDB,
           noiseFloorDBFS < t.maxNoiseFloorDBFS {
            reasons.append(.sparseSpikes)
        }

        if crestDB < t.maxDCCrestDB, abs(dcOffset) > t.minDCOffset {
            reasons.append(.dcOffset)
        }

        return reasons
    }

    func isJunk(_ t: JunkThresholds = .default) -> Bool {
        !junkReasons(t).isEmpty
    }

    /// Conservative fold of a stereo pair's per-channel stats into one verdict:
    /// whichever channel carries the most signal decides, so a pair is only junk
    /// when *both* sides are.
    static func merge(_ stats: [SignalStats]) -> SignalStats? {
        guard var best = stats.max(by: { $0.activeFraction < $1.activeFraction }) else { return nil }
        best.peak = stats.map(\.peak).max() ?? best.peak
        best.rms = stats.map(\.rms).max() ?? best.rms
        best.eventCount = stats.map(\.eventCount).max() ?? best.eventCount
        best.noiseFloor = stats.map(\.noiseFloor).max() ?? best.noiseFloor
        best.dcOffset = stats.map { abs($0.dcOffset) }.max() ?? best.dcOffset
        best.envelope = stats.dropFirst().reduce(stats[0].envelope) { $0.merged(with: $1.envelope) }
        return best
    }
}

// MARK: - Analyser

/// Incremental so it can serve both callers without either holding a whole
/// capture in RAM:
///   - the extractor, which already has the samples and feeds them in one go
///   - the review window, which streams a file from disk in chunks (a 30-minute
///     stereo capture is ~690 MB decoded, far too much to buffer)
///
/// `totalFrames` is known up front in both cases — `framesPerFile` at extraction,
/// `AVAudioFile.length` on read — which is what lets the envelope bucket
/// boundaries be fixed before the first sample arrives.
struct SignalAnalyzer {
    /// Activity window. 20 ms is short enough to resolve individual transients
    /// and long enough that the window level is meaningful at 44.1 kHz and up.
    static let windowSeconds: Double = 0.020

    /// Activity gate, relative to the channel's own peak. Scale-invariant, so a
    /// quiet capture is judged the same as a hot one.
    static let gateBelowPeakDB: Float = 30
    /// Release gate, lower than the trigger gate, so one transient's decay is
    /// not counted as several separate events.
    static let releaseBelowPeakDB: Float = 40

    static let envelopeBuckets = 2000
    static let maxTransients = 512

    private let totalFrames: Int
    private let sampleRate: Double
    private let windowFrames: Int
    private let bucketFrames: Int
    private let bucketCount: Int

    private var windowPeaks: [Float] = []
    private var envMin: [Float]
    private var envMax: [Float]

    private var globalPeak: Float = 0
    private var sumSquares: Double = 0
    private var sum: Double = 0
    private var framesSeen = 0

    // Carried across chunk boundaries.
    private var windowPeak: Float = 0
    private var windowRemaining: Int
    private var bucketMin: Float = .greatestFiniteMagnitude
    private var bucketMax: Float = -.greatestFiniteMagnitude
    private var bucketRemaining: Int
    private var bucketIndex = 0

    init(totalFrames: Int, sampleRate: Double) {
        self.totalFrames = totalFrames
        self.sampleRate = sampleRate
        self.windowFrames = max(1, Int(sampleRate * Self.windowSeconds))
        self.bucketCount = max(1, min(Self.envelopeBuckets, totalFrames))
        // Ceiling division so the last bucket never runs past the end.
        self.bucketFrames = max(1, (totalFrames + bucketCount - 1) / bucketCount)
        self.envMin = [Float](repeating: 0, count: bucketCount)
        self.envMax = [Float](repeating: 0, count: bucketCount)
        self.windowRemaining = windowFrames
        self.bucketRemaining = bucketFrames
        self.windowPeaks.reserveCapacity(totalFrames / windowFrames + 2)
    }

    /// Window and bucket boundaries are tracked with counters rather than a
    /// per-sample division, and both survive across calls.
    mutating func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }

        for i in 0..<samples.count {
            let s = base[i]
            let a = abs(s)

            if a > globalPeak { globalPeak = a }
            sumSquares += Double(s) * Double(s)
            sum += Double(s)

            if a > windowPeak { windowPeak = a }
            if s < bucketMin { bucketMin = s }
            if s > bucketMax { bucketMax = s }

            windowRemaining -= 1
            if windowRemaining == 0 {
                windowPeaks.append(windowPeak)
                windowPeak = 0
                windowRemaining = windowFrames
            }

            bucketRemaining -= 1
            if bucketRemaining == 0 {
                if bucketIndex < bucketCount {
                    envMin[bucketIndex] = bucketMin
                    envMax[bucketIndex] = bucketMax
                    bucketIndex += 1
                }
                bucketMin = .greatestFiniteMagnitude
                bucketMax = -.greatestFiniteMagnitude
                bucketRemaining = bucketFrames
            }
        }
        framesSeen += samples.count
    }

    mutating func consume(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { consume($0) }
    }

    /// Flushes the partial window / bucket and derives the activity profile.
    /// Call once — a second call would re-append the trailing partial window.
    mutating func finalize() -> SignalStats {
        guard framesSeen > 0 else {
            return SignalStats(
                frameCount: 0, sampleRate: sampleRate,
                peak: 0, rms: 0, dcOffset: 0,
                activeFraction: 0, eventCount: 0, noiseFloor: 0,
                transientFrames: [], envelope: .empty)
        }

        if windowRemaining != windowFrames {
            windowPeaks.append(windowPeak)
        }
        if bucketRemaining != bucketFrames, bucketIndex < bucketCount {
            envMin[bucketIndex] = bucketMin
            envMax[bucketIndex] = bucketMax
        }

        let rms = Float((sumSquares / Double(framesSeen)).squareRoot())
        let dc = Float(sum / Double(framesSeen))
        let profile = Self.activityProfile(
            windowPeaks: windowPeaks,
            globalPeak: globalPeak,
            windowFrames: windowFrames)

        return SignalStats(
            frameCount: framesSeen,
            sampleRate: sampleRate,
            peak: globalPeak,
            rms: rms,
            dcOffset: dc,
            activeFraction: profile.active,
            eventCount: profile.events,
            noiseFloor: profile.noiseFloor,
            transientFrames: profile.transients,
            envelope: WaveformEnvelope(minValues: envMin, maxValues: envMax))
    }

    /// One-shot convenience for callers that already hold the whole channel.
    static func analyze(_ samples: [Float], sampleRate: Double) -> SignalStats {
        samples.withUnsafeBufferPointer { analyze($0, sampleRate: sampleRate) }
    }

    static func analyze(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> SignalStats {
        var a = SignalAnalyzer(totalFrames: samples.count, sampleRate: sampleRate)
        a.consume(samples)
        return a.finalize()
    }

    /// Walk the per-window levels with a Schmitt trigger: cross the gate going
    /// up to open an event, fall below the (lower) release gate to close it.
    /// Hysteresis is what stops one transient's decay counting as several.
    private static func activityProfile(
        windowPeaks: [Float],
        globalPeak: Float,
        windowFrames: Int
    ) -> (active: Float, events: Int, noiseFloor: Float, transients: [Int]) {
        guard !windowPeaks.isEmpty, globalPeak > 0 else { return (0, 0, 0, []) }

        let gate = globalPeak * powf(10, -gateBelowPeakDB / 20)
        let release = globalPeak * powf(10, -releaseBelowPeakDB / 20)

        var activeWindows = 0
        var events = 0
        var transients: [Int] = []
        var inEvent = false

        for (i, level) in windowPeaks.enumerated() {
            if level >= gate {
                activeWindows += 1
                if !inEvent {
                    inEvent = true
                    events += 1
                    if transients.count < maxTransients {
                        transients.append(i * windowFrames)
                    }
                }
            } else if level < release {
                inEvent = false
            }
        }

        // Median window level — what sits between the events.
        let sorted = windowPeaks.sorted()
        let noiseFloor = sorted[sorted.count / 2]

        return (Float(activeWindows) / Float(windowPeaks.count), events, noiseFloor, transients)
    }
}

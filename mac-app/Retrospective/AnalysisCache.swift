// Persistent store for per-file `SignalStats`.
//
// Fresh captures seed this from the extractor, which already has the samples in
// RAM, so the review window opens instantly on anything just recorded. Older
// files are analysed lazily on first sight and then cached, keyed by path with
// (modified, size) as the validity check — so a retag, which rewrites the file,
// invalidates its entry automatically.
//
// Stored as a binary plist rather than JSON: entries carry a packed waveform
// envelope (see `WaveformEnvelope`'s Codable), and base64-in-JSON would roughly
// double it for no benefit.

import Foundation
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "AnalysisCache")

private struct CachedAnalysis: Codable {
    var modified: Date
    var size: Int64
    var stats: SignalStats
}

enum AnalysisError: LocalizedError {
    case bufferAllocationFailed
    case noChannelData

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: return "Could not allocate a read buffer."
        case .noChannelData:          return "Audio file produced no channel data."
        }
    }
}

actor AnalysisCache {
    static let shared = AnalysisCache()

    private var entries: [String: CachedAnalysis] = [:]
    private var loaded = false
    private var dirty = false

    private let storeURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Retrospective", isDirectory: true)
            .appendingPathComponent("analysis-cache.plist")
    }()

    // MARK: - Lookup

    /// Cached stats for `url`, or nil if absent or stale.
    func cached(for url: URL) -> SignalStats? {
        loadIfNeeded()
        guard let entry = entries[url.path], let id = Self.identity(of: url) else { return nil }
        guard entry.modified == id.modified, entry.size == id.size else { return nil }
        return entry.stats
    }

    /// Cached stats, analysing the file from disk on a miss.
    func stats(for url: URL) throws -> SignalStats {
        if let hit = cached(for: url) { return hit }
        let stats = try Self.analyzeFile(at: url)
        store(stats, for: url)
        return stats
    }

    /// Seed from samples already in memory — used by the extractor so a fresh
    /// capture never needs re-reading.
    func store(_ stats: SignalStats, for url: URL) {
        loadIfNeeded()
        guard let id = Self.identity(of: url) else { return }
        entries[url.path] = CachedAnalysis(modified: id.modified, size: id.size, stats: stats)
        dirty = true
    }

    func forget(_ url: URL) {
        loadIfNeeded()
        if entries.removeValue(forKey: url.path) != nil { dirty = true }
    }

    // MARK: - Persistence

    /// Drops entries whose file is gone, then writes if anything changed.
    func save() {
        guard loaded, dirty else { return }
        let before = entries.count
        entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        if entries.count != before { log.info("Pruned \(before - self.entries.count, privacy: .public) stale cache entries") }

        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(entries).write(to: storeURL, options: .atomic)
            dirty = false
        } catch {
            log.error("Cache save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            entries = try PropertyListDecoder().decode([String: CachedAnalysis].self, from: data)
            log.info("Loaded \(self.entries.count, privacy: .public) cached analyses")
        } catch {
            // A cache is disposable — a format change just means starting over.
            log.info("Cache unreadable, starting fresh: \(error.localizedDescription, privacy: .public)")
            entries = [:]
        }
    }

    private static func identity(of url: URL) -> (modified: Date, size: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return (modified, size.int64Value)
    }

    // MARK: - Decode

    /// Streams the file past a `SignalAnalyzer` per channel. Never holds more
    /// than `chunkFrames` in memory, so a 30-minute capture analyses in the same
    /// footprint as a 60-second one.
    nonisolated static func analyzeFile(at url: URL) throws -> SignalStats {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat          // deinterleaved float32
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(file.length)

        var analyzers = (0..<channelCount).map { _ in
            SignalAnalyzer(totalFrames: totalFrames, sampleRate: format.sampleRate)
        }

        let chunkFrames: AVAudioFrameCount = 1 << 18    // 262144 frames ≈ 5.5 s @ 48 kHz
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AnalysisError.bufferAllocationFailed
        }

        // Drive the loop off `framePosition` rather than reading until a short
        // read: AVAudioFile.read throws `nilError` when asked for frames past
        // the end, *even after* it has handed back every frame in the file. A
        // read-until-empty loop would therefore throw away a complete analysis
        // on the very last iteration of every file.
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            try file.read(into: buffer, frameCount: want)

            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channelData = buffer.floatChannelData else { throw AnalysisError.noChannelData }
            for c in 0..<channelCount {
                analyzers[c].consume(UnsafeBufferPointer(start: channelData[c], count: frames))
            }
        }

        let perChannel = (0..<channelCount).map { analyzers[$0].finalize() }
        guard let merged = SignalStats.merge(perChannel) else {
            throw AnalysisError.noChannelData
        }
        return merged
    }
}

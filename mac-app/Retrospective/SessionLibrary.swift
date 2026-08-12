// Turns the flat output folder into sessions for the review window.
//
// A "session" is one button press: every file sharing a capture timestamp. The
// output folder stays flat (see CLAUDE.md), so grouping is derived by parsing
// filenames rather than by directory structure.
//
// Session identity is the **timestamp**, not the whole filename stem. Tagging in
// M3 rewrites names and takes into the filename, and the grouping has to survive
// that.

import Foundation
import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "SessionLibrary")

// MARK: - Filename

/// Parser / formatter for `YYYY-MM-DD_HH-MM-SS[_<bpm>bpm][_<name>][_t<take>]_ch<NN>[-<MM>].wav`
/// as written by `ScratchExtractor.filenameStem`.
struct CaptureFilename: Equatable {
    /// The raw `yyyy-MM-dd_HH-mm-ss` text. Session identity — kept verbatim so
    /// grouping never depends on timezone or formatter round-tripping.
    var timestampText: String
    var timestamp: Date
    var bpm: Int?
    var name: String?
    var take: Int?
    /// 1-based, as written in the filename. One entry for mono, two for a pair.
    var channels: [Int]

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private static let timestampLength = 19     // "2026-08-11_14-23-05"

    static func parse(_ filename: String) -> CaptureFilename? {
        var stem = filename
        if let dot = stem.lastIndex(of: "."), stem[dot...].lowercased() == ".wav" {
            stem = String(stem[stem.startIndex..<dot])
        } else {
            return nil
        }

        // Anchor on the trailing channel token so anything the user types into
        // the middle (names with hyphens, digits, "bpm" in the text) can't
        // confuse the split.
        guard let chRange = stem.range(of: "_ch", options: .backwards) else { return nil }
        let channelText = String(stem[chRange.upperBound...])
        guard let channels = parseChannels(channelText) else { return nil }

        let head = String(stem[stem.startIndex..<chRange.lowerBound])
        guard head.count >= timestampLength else { return nil }
        let timestampText = String(head.prefix(timestampLength))
        guard let timestamp = dateFormatter.date(from: timestampText) else { return nil }

        var bpm: Int?
        var take: Int?
        var nameParts: [String] = []
        let middle = String(head.dropFirst(timestampLength))
        for token in middle.split(separator: "_") where !token.isEmpty {
            if token.hasSuffix("bpm"), let v = Int(token.dropLast(3)), bpm == nil {
                bpm = v
            } else if token.hasPrefix("t"), let v = Int(token.dropFirst()), take == nil {
                take = v
            } else {
                nameParts.append(String(token))
            }
        }

        return CaptureFilename(
            timestampText: timestampText,
            timestamp: timestamp,
            bpm: bpm,
            name: nameParts.isEmpty ? nil : nameParts.joined(separator: " "),
            take: take,
            channels: channels)
    }

    /// "01" → [1]; "03-04" → [3, 4].
    private static func parseChannels(_ text: String) -> [Int]? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isNumber), let v = Int(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Rebuilds the filename. Used by the retagger when a name or take changes.
    func formatted() -> String {
        var parts = [timestampText]
        if let bpm { parts.append("\(bpm)bpm") }
        if let name, !name.isEmpty { parts.append(Self.sanitize(name)) }
        if let take { parts.append("t\(take)") }

        let channelText = channels.count == 2
            ? String(format: "ch%02d-%02d", channels[0], channels[1])
            : String(format: "ch%02d", channels.first ?? 0)
        parts.append(channelText)
        return parts.joined(separator: "_") + ".wav"
    }

    /// Longest name segment allowed in a filename.
    ///
    /// macOS caps a filename at 255 bytes and the other segments (timestamp,
    /// bpm, take, channel, extension) account for roughly 50. Truncating here
    /// rather than letting the rename fail matters because the retagger has
    /// already rewritten the file by the time it renames it. The untruncated
    /// name is still written to iXML, so nothing is lost.
    static let maxNameLength = 60

    /// Filename-safe form of a user-typed name. Underscore is the field
    /// separator so it must not survive; `/` and `:` are illegal on macOS.
    static func sanitize(_ name: String) -> String {
        let mapped = name.map { ch -> Character in
            if ch == "_" || ch == "/" || ch == ":" || ch.isWhitespace { return "-" }
            return ch
        }
        // Collapse runs of hyphens and trim the ends.
        var out = ""
        var lastWasHyphen = false
        for ch in mapped {
            if ch == "-" {
                if !lastWasHyphen { out.append(ch) }
                lastWasHyphen = true
            } else {
                out.append(ch)
                lastWasHyphen = false
            }
        }
        if out.count > maxNameLength {
            out = String(out.prefix(maxNameLength))
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - Models

struct CaptureFile: Identifiable, Hashable {
    var url: URL
    var channels: [Int]

    var id: URL { url }
    var isStereo: Bool { channels.count == 2 }

    var channelLabel: String {
        channels.count == 2
            ? String(format: "ch%02d-%02d", channels[0], channels[1])
            : String(format: "ch%02d", channels.first ?? 0)
    }

    static func == (a: CaptureFile, b: CaptureFile) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

struct CaptureSession: Identifiable, Equatable {
    var id: String              // timestampText
    var timestamp: Date
    var bpm: Int?
    var name: String?
    var take: Int?
    var files: [CaptureFile]

    var title: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: timestamp)
    }

    var dateText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: timestamp)
    }

    var subtitle: String {
        var parts = ["\(files.count) file\(files.count == 1 ? "" : "s")"]
        if let bpm { parts.append("\(bpm) bpm") }
        if let take { parts.append("take \(take)") }
        return parts.joined(separator: " · ")
    }

    static func == (a: CaptureSession, b: CaptureSession) -> Bool {
        a.id == b.id && a.files == b.files && a.name == b.name && a.take == b.take
    }
}

// MARK: - Grouping

/// A run of captures close together in time — one sitting at the rig.
///
/// Vocabulary note: a `CaptureSession` in this codebase is **one button press**.
/// A `CaptureGroup` is what you would colloquially call a session: several
/// presses over one stretch of playing. Nothing in the filenames records a
/// sitting, so it is inferred from the gap between consecutive captures.
///
/// The default 30-minute gap comes from the real library: gaps within a sitting
/// topped out at 20.4 minutes and the next gap up was 52.9 minutes, so 30 sits
/// in empty space between the two populations.
struct CaptureGroup: Identifiable, Equatable {
    var id: String
    var captures: [CaptureSession]

    var start: Date { captures.last?.timestamp ?? .distantPast }
    var end: Date { captures.first?.timestamp ?? .distantPast }

    /// "Fri 5 Jun"
    var title: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: end)
    }

    /// "11:48 – 12:16 · 8 captures"
    var subtitle: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        let span = captures.count > 1
            ? "\(f.string(from: start)) – \(f.string(from: end))"
            : f.string(from: end)
        return "\(span) · \(captures.count) capture\(captures.count == 1 ? "" : "s")"
    }
}

// MARK: - Library

@MainActor
final class SessionLibrary: ObservableObject {
    @Published private(set) var sessions: [CaptureSession] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    /// Analysis results by file. Populated lazily — the selected session first,
    /// then the rest in the background so junk badges fill in progressively.
    @Published private(set) var stats: [URL: SignalStats] = [:]
    @Published private(set) var analyzing: Set<URL> = []

    @Published var thresholds: JunkThresholds = .default

    /// Captures further apart than this start a new group. See `CaptureGroup`.
    @Published var groupGapMinutes: Double = 30

    static let groupGapKey = "review.groupGapMinutes"

    private var backgroundScan: Task<Void, Never>?

    /// Sessions folded into sittings for the sidebar.
    var groups: [CaptureGroup] {
        Self.group(sessions, gapMinutes: groupGapMinutes)
    }

    /// `sessions` arrives newest-first, so consecutive pairs are compared
    /// backwards in time. Pure — `nonisolated` so it is testable directly.
    nonisolated static func group(_ sessions: [CaptureSession], gapMinutes: Double) -> [CaptureGroup] {
        guard !sessions.isEmpty else { return [] }
        let gap = max(1, gapMinutes) * 60

        var groups: [CaptureGroup] = []
        var current: [CaptureSession] = [sessions[0]]

        for session in sessions.dropFirst() {
            let previous = current[current.count - 1].timestamp
            if previous.timeIntervalSince(session.timestamp) > gap {
                groups.append(CaptureGroup(id: current[0].id, captures: current))
                current = [session]
            } else {
                current.append(session)
            }
        }
        groups.append(CaptureGroup(id: current[0].id, captures: current))
        return groups
    }

    /// Flagged files across a whole sitting, so a bad one is visible without
    /// opening each capture. nil while any of it is still unanalysed.
    func junkCount(in group: CaptureGroup) -> Int? {
        var total = 0
        for capture in group.captures {
            guard let n = junkCount(in: capture) else { return nil }
            total += n
        }
        return total
    }

    // MARK: Scan

    /// Awaitable so callers that mutate files (trash, combine) can rescan and
    /// then reload the player against the new file set, in order.
    func refresh(root: URL) async {
        isScanning = true
        backgroundScan?.cancel()

        let found = await Self.scan(root: root)
        sessions = found
        isScanning = false
        log.info("Found \(found.count, privacy: .public) sessions under \(root.path, privacy: .public)")
        startBackgroundAnalysis()
    }

    /// Internal rather than private so tests can drive grouping directly,
    /// without the shared analysis cache in the way.
    nonisolated static func scan(root: URL) async -> [CaptureSession] {
        await Task.detached(priority: .userInitiated) { () -> [CaptureSession] in
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            else { return [] }

            var grouped: [String: CaptureSession] = [:]
            for url in urls {
                guard url.pathExtension.lowercased() == "wav",
                      let parsed = CaptureFilename.parse(url.lastPathComponent)
                else { continue }

                let file = CaptureFile(url: url, channels: parsed.channels)
                if grouped[parsed.timestampText] != nil {
                    grouped[parsed.timestampText]?.files.append(file)
                } else {
                    grouped[parsed.timestampText] = CaptureSession(
                        id: parsed.timestampText,
                        timestamp: parsed.timestamp,
                        bpm: parsed.bpm,
                        name: parsed.name,
                        take: parsed.take,
                        files: [file])
                }
            }

            return grouped.values
                .map { session in
                    var s = session
                    s.files.sort { ($0.channels.first ?? 0) < ($1.channels.first ?? 0) }
                    return s
                }
                .sorted { $0.timestamp > $1.timestamp }    // newest first
        }.value
    }

    // MARK: Analysis

    /// Analyse one session's files concurrently. Cheap for fresh captures — the
    /// extractor has already seeded the cache.
    func analyze(_ session: CaptureSession) async {
        let pending = session.files.map(\.url).filter { stats[$0] == nil && !analyzing.contains($0) }
        guard !pending.isEmpty else { return }
        analyzing.formUnion(pending)

        await withTaskGroup(of: (URL, SignalStats?).self) { group in
            for url in pending {
                group.addTask(priority: .userInitiated) {
                    do {
                        return (url, try await AnalysisCache.shared.stats(for: url))
                    } catch {
                        log.error("Analysis failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return (url, nil)
                    }
                }
            }
            for await (url, result) in group {
                analyzing.remove(url)
                if let result { stats[url] = result }
            }
        }
        await AnalysisCache.shared.save()
    }

    /// Walk every session at low priority so the sidebar's junk badges appear
    /// without the user having to visit each session first.
    private func startBackgroundAnalysis() {
        backgroundScan = Task(priority: .background) {
            for session in sessions {
                if Task.isCancelled { return }
                await analyze(session)
            }
        }
    }

    // MARK: Derived

    func stats(for file: CaptureFile) -> SignalStats? { stats[file.url] }

    func junkReasons(for file: CaptureFile) -> [JunkReason] {
        stats[file.url]?.junkReasons(thresholds) ?? []
    }

    func isJunk(_ file: CaptureFile) -> Bool { !junkReasons(for: file).isEmpty }

    /// nil while any file in the session is still unanalysed, so the UI can
    /// distinguish "no junk" from "not yet known".
    func junkCount(in session: CaptureSession) -> Int? {
        guard session.files.allSatisfy({ stats[$0.url] != nil }) else { return nil }
        return session.files.filter(isJunk).count
    }

    func session(withID id: String) -> CaptureSession? {
        sessions.first { $0.id == id }
    }

    /// Drop cached state for files that have gone away (trashed or combined).
    func forget(_ files: [CaptureFile]) {
        for file in files { stats.removeValue(forKey: file.url) }
        Task { for file in files { await AnalysisCache.shared.forget(file.url) } }
    }

    // MARK: - Cleanup

    /// Every junk-flagged file across every analysed session.
    func flaggedFiles(in session: CaptureSession) -> [CaptureFile] {
        session.files.filter(isJunk)
    }

    /// Moves files to the Trash — never unlinks them. A capture cannot be
    /// re-recorded, so a misjudged cleanup has to be recoverable from Finder.
    ///
    /// - Returns: the files actually trashed.
    @discardableResult
    func trash(_ files: [CaptureFile], root: URL) async -> [CaptureFile] {
        var trashed: [CaptureFile] = []
        for file in files {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: file.url, resultingItemURL: &resulting)
                trashed.append(file)
            } catch {
                lastError = "Could not trash \(file.url.lastPathComponent): \(error.localizedDescription)"
                log.error("Trash failed for \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !trashed.isEmpty {
            log.info("Trashed \(trashed.count, privacy: .public) files")
            forget(trashed)
            await refresh(root: root)
        }
        return trashed
    }

    /// Combines two mono files in a session into one interleaved stereo file.
    func combine(
        _ a: CaptureFile,
        _ b: CaptureFile,
        in session: CaptureSession,
        root: URL,
        appVersion: String
    ) async {
        do {
            try StereoCombiner.combine(left: a, right: b, session: session, appVersion: appVersion)
            forget([a, b])
            lastError = nil
            await refresh(root: root)
        } catch {
            lastError = error.localizedDescription
            log.error("Combine failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearError() { lastError = nil }

    func report(error message: String) { lastError = message }
}

// Applies session tags to captures that are already on disk.
//
// Tagging happens in review, after extraction, so the metadata chunks have to be
// inserted into existing files. Chunks sit *before* the audio in a RIFF file and
// change size, so this is a rewrite rather than a patch: build a fresh header,
// stream the untouched `data` payload after it, then swap the file in via
// `replaceItemAt`. That swap is atomic — a crash or a full disk mid-write leaves
// the original capture intact, which matters because these takes cannot be
// re-recorded.
//
// The audio payload is copied byte-for-byte and never decoded, so retagging is
// lossless no matter how many times it is applied.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "Retagger")

/// The tags a user can apply to a whole capture from the review window.
struct SessionTags: Equatable {
    var name: String?
    var take: Int?
    var note: String?
    var goodTake: Bool = false

    var isEmpty: Bool {
        (name?.isEmpty ?? true) && take == nil && (note?.isEmpty ?? true) && !goodTake
    }

    /// Surrounding whitespace is stripped on the way in because the reader
    /// strips it on the way out — without this, tagging a name typed with a
    /// trailing space would never compare equal to what comes back, and the
    /// "Apply Tags" button would stay lit forever.
    var trimmed: SessionTags {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        return SessionTags(name: clean(name), take: take, note: clean(note), goodTake: goodTake)
    }
}

enum RetagError: LocalizedError {
    case missingChunk(String)
    case unsupportedFormat
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .missingChunk(let id):  return "File has no \(id) chunk."
        case .unsupportedFormat:     return "Only 32-bit float WAVs can be retagged."
        case .destinationExists(let name): return "\(name) already exists."
        }
    }
}

enum Retagger {

    /// Rewrites `file` with `tags` embedded, renaming it if the tags change the
    /// filename. Returns the file's URL afterwards.
    @discardableResult
    static func apply(
        _ rawTags: SessionTags,
        to file: CaptureFile,
        in session: CaptureSession,
        appVersion: String = "0.0.0"
    ) throws -> URL {
        let tags = rawTags.trimmed
        let chunks = try WAVReader.chunks(at: file.url)

        guard let fmt = chunks.first(where: { $0.id == "fmt " }) else {
            throw RetagError.missingChunk("fmt ")
        }
        guard let data = chunks.first(where: { $0.id == "data" }) else {
            throw RetagError.missingChunk("data")
        }

        let fmtData = try WAVReader.payload(of: fmt, at: file.url)
        guard fmtData.count >= 16 else { throw RetagError.unsupportedFormat }
        let formatTag = fmtData.u16(0)
        let channelCount = Int(fmtData.u16(2))
        let sampleRate = Double(fmtData.u32(4))
        let bitsPerSample = fmtData.u16(14)
        guard formatTag == 3, bitsPerSample == 32, channelCount > 0 else {
            throw RetagError.unsupportedFormat
        }

        let frameCount = data.payloadSize / (channelCount * 4)
        let metadata = WAVMetadata(
            captureTimestamp: session.timestamp,
            comment: comment(for: session, tags: tags),
            software: "seeed-recorder/\(appVersion)",
            sessionName: tags.name?.isEmpty == false ? tags.name : nil,
            take: tags.take,
            note: tags.note?.isEmpty == false ? tags.note : nil,
            goodTake: tags.goodTake,
            bpm: session.bpm.map(Double.init))

        let header = WAVWriter.buildHeader(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            metadata: metadata)

        // Temp file in the same directory so the replace is a rename, not a copy
        // across volumes.
        let tempURL = file.url.deletingLastPathComponent()
            .appendingPathComponent(".retag-\(UUID().uuidString).wav")
        do {
            try writeRetagged(source: file.url, dataChunk: data, header: header, to: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // Atomic in-place swap first, rename second: if the rename fails we
        // still have a correctly tagged file, just under the old name.
        _ = try FileManager.default.replaceItemAt(file.url, withItemAt: tempURL)

        let newURL = file.url.deletingLastPathComponent()
            .appendingPathComponent(filename(for: session, tags: tags, channels: file.channels))
        if newURL != file.url {
            guard !FileManager.default.fileExists(atPath: newURL.path) else {
                throw RetagError.destinationExists(newURL.lastPathComponent)
            }
            try FileManager.default.moveItem(at: file.url, to: newURL)
        }

        log.info("Retagged \(newURL.lastPathComponent, privacy: .public)")
        return newURL
    }

    /// Applies to every file in a session. Collects per-file failures rather
    /// than aborting, so one bad file cannot leave the session half-tagged with
    /// no report of which.
    static func applyToSession(
        _ tags: SessionTags,
        session: CaptureSession,
        appVersion: String = "0.0.0"
    ) -> (updated: [URL], errors: [(file: String, message: String)]) {
        var updated: [URL] = []
        var errors: [(String, String)] = []
        for file in session.files {
            do {
                updated.append(try apply(tags, to: file, in: session, appVersion: appVersion))
            } catch {
                errors.append((file.url.lastPathComponent, error.localizedDescription))
                log.error("Retag failed for \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return (updated, errors)
    }

    /// The filename a session's file should carry once tagged. Sanitising means
    /// a name typed with spaces round-trips to the same filename every time, so
    /// re-applying an unchanged tag is a no-op rather than a rename each pass.
    static func filename(for session: CaptureSession, tags: SessionTags, channels: [Int]) -> String {
        CaptureFilename(
            timestampText: session.id,
            timestamp: session.timestamp,
            bpm: session.bpm,
            name: tags.name?.isEmpty == false ? tags.name : nil,
            take: tags.take,
            channels: channels
        ).formatted()
    }

    private static func comment(for session: CaptureSession, tags: SessionTags) -> String {
        var parts: [String] = []
        if let bpm = session.bpm { parts.append("BPM=\(bpm)") }
        if let name = tags.name, !name.isEmpty { parts.append("Scene=\(name)") }
        if let take = tags.take { parts.append("Take=\(take)") }
        if tags.goodTake { parts.append("Circled=TRUE") }
        if let note = tags.note, !note.isEmpty { parts.append("Note=\(note)") }
        parts.append("Source=seeed-recorder")
        return parts.joined(separator: "; ")
    }

    // MARK: - Streaming rewrite

    private static func writeRetagged(
        source: URL,
        dataChunk: WAVChunk,
        header: Data,
        to destination: URL
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }

        try output.write(contentsOf: header)
        try input.seek(toOffset: UInt64(dataChunk.payloadOffset))

        var remaining = dataChunk.payloadSize
        let chunkBytes = 1 << 20      // 1 MB
        while remaining > 0 {
            let want = min(chunkBytes, remaining)
            guard let block = try input.read(upToCount: want), !block.isEmpty else {
                throw WAVReadError.truncated
            }
            try output.write(contentsOf: block)
            remaining -= block.count
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }
    func u32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
}

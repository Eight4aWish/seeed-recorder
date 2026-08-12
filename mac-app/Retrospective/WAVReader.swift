// Minimal RIFF chunk walker — enough to read back the tags we write and to
// locate the audio payload for a rewrite.
//
// AVAudioFile handles decoding; it does not expose `bext` or `iXML`, so the
// review window needs its own parse to show what a file is already tagged with
// and to make re-applying the same tag a no-op rather than a rename loop.
//
// Only the header region is read — chunks are walked by their size fields, so a
// 345 MB capture costs the same as a small one.

import Foundation

struct WAVChunk {
    let id: String
    /// Offset of the chunk's payload (i.e. after the 8-byte id + size).
    let payloadOffset: Int
    let payloadSize: Int
}

/// Session tags recovered from a file's `bext` / `iXML` chunks.
struct WAVTags: Equatable {
    var sessionName: String?
    var take: Int?
    var note: String?
    var goodTake: Bool = false
    var project: String?
    var description: String?

    var isEmpty: Bool {
        sessionName == nil && take == nil && note == nil && !goodTake
    }
}

enum WAVReadError: LocalizedError {
    case notRIFF
    case truncated

    var errorDescription: String? {
        switch self {
        case .notRIFF:   return "Not a RIFF/WAVE file."
        case .truncated: return "File ended mid-chunk."
        }
    }
}

enum WAVReader {

    /// Walks the top-level chunk list. Reads only as much of the file as the
    /// chunk headers require.
    static func chunks(at url: URL) throws -> [WAVChunk] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let riff = try handle.read(upToCount: 12), riff.count == 12,
              riff.prefix(4) == Data("RIFF".utf8),
              riff.subdata(in: 8..<12) == Data("WAVE".utf8)
        else { throw WAVReadError.notRIFF }

        var chunks: [WAVChunk] = []
        var offset = 12

        while true {
            try handle.seek(toOffset: UInt64(offset))
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }

            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let size = Int(header.subdata(in: 4..<8).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })

            chunks.append(WAVChunk(id: id, payloadOffset: offset + 8, payloadSize: size))

            // Chunks are word-aligned: an odd size is followed by a pad byte.
            offset += 8 + size + (size % 2)
        }
        return chunks
    }

    static func payload(of chunk: WAVChunk, at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(chunk.payloadOffset))
        guard let data = try handle.read(upToCount: chunk.payloadSize),
              data.count == chunk.payloadSize
        else { throw WAVReadError.truncated }
        return data
    }

    /// Reads session tags. iXML wins where both carry a field, since it is the
    /// structured source; `bext` Description is only a rendering of it.
    static func tags(at url: URL) throws -> WAVTags {
        let all = try chunks(at: url)
        var tags = WAVTags()

        if let bext = all.first(where: { $0.id == "bext" }),
           let data = try? payload(of: bext, at: url), data.count >= 256 {
            tags.description = trimFixed(data.prefix(256))
            tags.project = trimFixed(data.subdata(in: 288..<320))   // OriginatorReference
        }

        if let ixml = all.first(where: { $0.id == "iXML" }),
           let data = try? payload(of: ixml, at: url) {
            let xml = String(decoding: data, as: UTF8.self)
            tags.sessionName = element("SCENE", in: xml)
            tags.take = element("TAKE", in: xml).flatMap(Int.init)
            tags.note = element("NOTE", in: xml)
            tags.goodTake = element("CIRCLED", in: xml)?.uppercased() == "TRUE"
            if let project = element("PROJECT", in: xml) { tags.project = project }
        }
        return tags
    }

    // MARK: - Helpers

    /// `bext` fields are null-padded fixed-width.
    private static func trimFixed(_ data: Data) -> String? {
        let bytes = Array(data)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        let s = String(decoding: bytes[0..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    /// Shallow element lookup. The documents we read are the ones we wrote —
    /// flat, no namespaces — so this avoids pulling in XMLParser for five fields.
    /// `NOTE` is looked up outermost-first so a `<SPEED><NOTE>` does not shadow
    /// the session note.
    private static func element(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        let value = String(xml[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : unescapeXML(value)
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")   // last, or it double-decodes
    }
}

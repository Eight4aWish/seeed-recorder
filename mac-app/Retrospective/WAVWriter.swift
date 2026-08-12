// Minimal 32-bit float WAV writer (WAVE_FORMAT_IEEE_FLOAT, format=3) with
// optional LIST-INFO metadata.
//
// Logic Pro, Ableton 11+, Pro Tools, and Audacity all read 32-bit float WAVs.
// We pick this over PCM int24 because:
//   1. The capture is already Float32 — no quantization on save.
//   2. Captured signal can briefly exceed 0 dBFS without clipping.
//
// File layout for an N-channel float WAV with metadata:
//   "RIFF" | riffSize | "WAVE"                       (12 bytes)
//   "fmt " | 16 | formatTag=3 | numCh | sampleRate |
//      byteRate | blockAlign | bitsPerSample=32      (24 bytes)
//   "LIST" | listSize | "INFO" | <sub-chunks>        (variable, optional)
//   "data" | dataSize | <interleaved float32 samples>

import Foundation

struct WAVMetadata: Sendable {
    /// Wall-clock at trigger time. Encoded as ISO-8601 in the ICRD chunk, and as
    /// OriginationDate / OriginationTime in `bext`.
    let captureTimestamp: Date
    /// Free-form comment encoded in the ICMT chunk. Per the recorder protocol:
    /// `BPM=<n>; Link=<playing|stopped>; Source=<id>` (BPM/Link fields omitted
    /// when no Link tempo is available).
    let comment: String
    /// Software identifier encoded in the ISFT chunk, e.g. `seeed-recorder/0.1.0`.
    let software: String

    // MARK: Session tags
    //
    // Applied after the fact from the review window. All optional and defaulted
    // so the extractor's existing call site is unaffected.

    /// iXML `SCENE`. Resolve surfaces this in the Metadata panel and makes it
    /// searchable in the Media Pool.
    var sessionName: String?
    /// iXML `TAKE`.
    var take: Int?
    /// iXML `NOTE`.
    var note: String?
    /// iXML `CIRCLED` — the field-recorder convention for "this was the good one".
    var goodTake: Bool = false
    var bpm: Double?
    /// iXML `PROJECT`.
    var project: String = "Retrospective"
    /// `bext` TimeReference, in samples since midnight. Held at 0 by design: all
    /// files from one press then share a timecode and auto-align to each other
    /// in Resolve, without captures scattering across a 24-hour timeline.
    var timeReferenceSamples: UInt64 = 0

    /// True when there is anything worth writing into `bext` / `iXML` beyond the
    /// capture timestamp.
    var hasSessionTags: Bool {
        sessionName != nil || take != nil || note != nil || goodTake
    }

    /// Human-readable one-liner for the `bext` Description field, which is what
    /// Resolve shows as "Description".
    var descriptionLine: String {
        var parts: [String] = []
        if let sessionName, !sessionName.isEmpty { parts.append(sessionName) }
        if let take { parts.append("take \(take)") }
        if let bpm, bpm > 0 { parts.append("\(Int(bpm.rounded())) BPM") }
        if goodTake { parts.append("circled") }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? "seeed-recorder capture" : parts.joined(separator: " | ")
    }
}

enum WAVWriter {
    /// Builds everything up to and including the `data` chunk header.
    ///
    /// Split out from `writeFloat32` so callers that produce samples
    /// incrementally — `StereoCombiner`, which interleaves two files without
    /// decoding either in full — can emit an identical header and then stream.
    static func buildHeader(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        metadata: WAVMetadata? = nil
    ) -> Data {
        let bitsPerSample: UInt16 = 32
        let bytesPerSample = Int(bitsPerSample / 8)
        let blockAlign = UInt16(channelCount * bytesPerSample)
        let byteRate   = UInt32(sampleRate) * UInt32(blockAlign)
        let dataBytes  = frameCount * channelCount * bytesPerSample

        // Chunk order: fmt → bext → iXML → LIST → data. bext and iXML are what
        // DaVinci Resolve reads; LIST-INFO stays for backward compatibility with
        // captures already on disk.
        let bextChunk: Data? = metadata.map(buildBextChunk)
        let ixmlChunk: Data? = metadata.map(buildIXMLChunk)
        let listChunk: Data? = metadata.map(buildListInfoChunk)
        let metaBytes = (bextChunk?.count ?? 0) + (ixmlChunk?.count ?? 0) + (listChunk?.count ?? 0)

        // RIFF "size" field excludes the leading "RIFF" + size words (8 bytes).
        let riffBytes = 4 /*"WAVE"*/ + 24 /*fmt chunk*/ + metaBytes + 8 /*data hdr*/ + dataBytes

        var header = Data()
        header.reserveCapacity(12 + 24 + metaBytes + 8)

        header.appendASCII("RIFF")
        header.append(uint32LE: UInt32(riffBytes))
        header.appendASCII("WAVE")

        header.appendASCII("fmt ")
        header.append(uint32LE: 16)
        header.append(uint16LE: 3)              // WAVE_FORMAT_IEEE_FLOAT
        header.append(uint16LE: UInt16(channelCount))
        header.append(uint32LE: UInt32(sampleRate))
        header.append(uint32LE: byteRate)
        header.append(uint16LE: blockAlign)
        header.append(uint16LE: bitsPerSample)

        if let bext = bextChunk { header.append(bext) }
        if let ixml = ixmlChunk { header.append(ixml) }
        if let list = listChunk { header.append(list) }

        header.appendASCII("data")
        header.append(uint32LE: UInt32(dataBytes))
        return header
    }

    static func writeFloat32(
        url: URL,
        sampleRate: Double,
        channels: [[Float]],
        metadata: WAVMetadata? = nil
    ) throws {
        precondition(!channels.isEmpty, "Need at least one channel.")
        let numChannels = channels.count
        let frameCount  = channels[0].count
        precondition(channels.allSatisfy { $0.count == frameCount },
                     "All channels must have the same frame count.")

        let bytesPerSample = 4
        let header = buildHeader(
            sampleRate: sampleRate,
            channelCount: numChannels,
            frameCount: frameCount,
            metadata: metadata)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)

        // Interleave samples in chunks to avoid one giant allocation.
        let chunkFrames = 8192
        var f = 0
        var buffer = [Float](repeating: 0, count: chunkFrames * numChannels)
        while f < frameCount {
            let n = min(chunkFrames, frameCount - f)
            for i in 0..<n {
                for ch in 0..<numChannels {
                    buffer[i * numChannels + ch] = channels[ch][f + i]
                }
            }
            try buffer.withUnsafeBufferPointer { bp in
                let bytes = Data(bytes: bp.baseAddress!, count: n * numChannels * bytesPerSample)
                try handle.write(contentsOf: bytes)
            }
            f += n
        }
    }

    // MARK: - bext (Broadcast Wave)
    //
    // EBU Tech 3285. Fixed 602-byte struct; we emit Version 1 (UMID present,
    // loudness fields left as reserved zeros) because we have no loudness
    // measurements and Version 2 requires 0x7FFF sentinels for absent ones.
    //
    //   Description         256   Originator            32
    //   OriginatorReference  32   OriginationDate       10  ("yyyy-mm-dd")
    //   OriginationTime       8   TimeReferenceLow/High  8
    //   Version               2   UMID                  64
    //   Reserved            180 + 10 loudness bytes = 190
    //
    // Resolve reads Description, the origination date/time, and TimeReference
    // (which drives source timecode, and therefore Auto Sync by Timecode).

    static let bextChunkSize = 602

    private static func buildBextChunk(_ m: WAVMetadata) -> Data {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm:ss"

        var body = Data()
        body.appendFixedASCII(m.descriptionLine, length: 256)
        body.appendFixedASCII("seeed-recorder", length: 32)
        body.appendFixedASCII(m.project, length: 32)
        body.appendFixedASCII(dateFormatter.string(from: m.captureTimestamp), length: 10)
        body.appendFixedASCII(timeFormatter.string(from: m.captureTimestamp), length: 8)
        body.append(uint32LE: UInt32(truncatingIfNeeded: m.timeReferenceSamples))
        body.append(uint32LE: UInt32(truncatingIfNeeded: m.timeReferenceSamples >> 32))
        body.append(uint16LE: 1)                                  // Version
        body.append(Data(repeating: 0, count: 64))                // UMID (unset)
        body.append(Data(repeating: 0, count: 190))               // loudness + reserved

        assert(body.count == bextChunkSize, "bext body must be exactly \(bextChunkSize) bytes, got \(body.count)")

        var chunk = Data()
        chunk.appendASCII("bext")
        chunk.append(uint32LE: UInt32(body.count))
        chunk.append(body)
        return chunk                                              // 602 is even; no pad
    }

    // MARK: - iXML
    //
    // The field-recorder metadata standard. Resolve 20.2+ reads these actively:
    // SCENE, TAKE and NOTE appear in the Metadata panel and are searchable in
    // the Media Pool, and CIRCLED marks a good take.

    private static func buildIXMLChunk(_ m: WAVMetadata) -> Data {
        let tapeFormatter = DateFormatter()
        tapeFormatter.locale = Locale(identifier: "en_US_POSIX")
        tapeFormatter.dateFormat = "yyyy-MM-dd"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <BWFXML>
        <IXML_VERSION>1.5</IXML_VERSION>
        <PROJECT>\(escapeXML(m.project))</PROJECT>
        <TAPE>\(tapeFormatter.string(from: m.captureTimestamp))</TAPE>

        """
        if let name = m.sessionName, !name.isEmpty {
            xml += "<SCENE>\(escapeXML(name))</SCENE>\n"
        }
        if let take = m.take {
            xml += "<TAKE>\(take)</TAKE>\n"
        }
        if m.goodTake {
            xml += "<CIRCLED>TRUE</CIRCLED>\n"
        }
        if let note = m.note, !note.isEmpty {
            xml += "<NOTE>\(escapeXML(note))</NOTE>\n"
        }
        if let bpm = m.bpm, bpm > 0 {
            // No standard iXML tempo field; SPEED/NOTE is where recorders put
            // free-form speed information and it survives into Resolve.
            xml += "<SPEED>\n<NOTE>\(Int(bpm.rounded())) BPM</NOTE>\n</SPEED>\n"
        }
        xml += "</BWFXML>\n"

        var body = Data(xml.utf8)
        if body.count % 2 != 0 { body.append(0x20) }   // pad inside the payload

        var chunk = Data()
        chunk.appendASCII("iXML")
        chunk.append(uint32LE: UInt32(body.count))
        chunk.append(body)
        return chunk
    }

    private static func escapeXML(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&apos;"
            default:   out.append(ch)
            }
        }
        return out
    }

    // MARK: - LIST/INFO

    private static func buildListInfoChunk(_ m: WAVMetadata) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let icrd = iso.string(from: m.captureTimestamp)

        var info = Data()
        info.appendASCII("INFO")
        info.appendInfoSubChunk("ICMT", m.comment)
        info.appendInfoSubChunk("ICRD", icrd)
        info.appendInfoSubChunk("ISFT", m.software)

        var chunk = Data()
        chunk.appendASCII("LIST")
        chunk.append(uint32LE: UInt32(info.count))
        chunk.append(info)
        return chunk
    }
}

private extension Data {
    mutating func appendASCII(_ s: String) {
        append(contentsOf: s.utf8)
    }
    /// Fixed-width, null-padded field as used throughout `bext`. Truncates on a
    /// UTF-8 byte boundary so a multi-byte character can't be cut in half.
    mutating func appendFixedASCII(_ s: String, length: Int) {
        var bytes = Array(s.utf8)
        if bytes.count > length {
            var end = length
            // Back off any trailing continuation bytes (0b10xxxxxx).
            while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
            bytes = Array(bytes[0..<end])
        }
        append(contentsOf: bytes)
        append(Data(repeating: 0, count: length - bytes.count))
    }
    mutating func append(uint16LE v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func append(uint32LE v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    /// LIST/INFO sub-chunk: 4-byte ASCII id, 4-byte LE size, null-terminated
    /// payload, padded to an even byte count.
    mutating func appendInfoSubChunk(_ id: String, _ value: String) {
        precondition(id.count == 4)
        var payload = Array(value.utf8)
        payload.append(0)   // null terminator
        let dataSize = payload.count
        appendASCII(id)
        append(uint32LE: UInt32(dataSize))
        append(contentsOf: payload)
        if dataSize % 2 != 0 {
            append(0)       // pad to word boundary
        }
    }
}

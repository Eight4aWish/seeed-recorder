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
    /// Wall-clock at trigger time. Encoded as ISO-8601 in the ICRD chunk.
    let captureTimestamp: Date
    /// Free-form comment encoded in the ICMT chunk. Per the recorder protocol:
    /// `BPM=<n>; Link=<playing|stopped>; Source=<id>` (BPM/Link fields omitted
    /// when no Link tempo is available).
    let comment: String
    /// Software identifier encoded in the ISFT chunk, e.g. `seeed-recorder/0.1.0`.
    let software: String
}

enum WAVWriter {
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

        let bitsPerSample: UInt16 = 32
        let bytesPerSample = Int(bitsPerSample / 8)
        let blockAlign = UInt16(numChannels * bytesPerSample)
        let byteRate   = UInt32(sampleRate) * UInt32(blockAlign)
        let dataBytes  = frameCount * numChannels * bytesPerSample

        let listChunk: Data? = metadata.map(buildListInfoChunk)
        let listBytes = listChunk?.count ?? 0

        // RIFF "size" field excludes the leading "RIFF" + size words (8 bytes).
        let riffBytes = 4 /*"WAVE"*/ + 24 /*fmt chunk*/ + listBytes + 8 /*data hdr*/ + dataBytes

        var header = Data()
        header.reserveCapacity(12 + 24 + listBytes + 8)

        header.appendASCII("RIFF")
        header.append(uint32LE: UInt32(riffBytes))
        header.appendASCII("WAVE")

        header.appendASCII("fmt ")
        header.append(uint32LE: 16)
        header.append(uint16LE: 3)              // WAVE_FORMAT_IEEE_FLOAT
        header.append(uint16LE: UInt16(numChannels))
        header.append(uint32LE: UInt32(sampleRate))
        header.append(uint32LE: byteRate)
        header.append(uint16LE: blockAlign)
        header.append(uint16LE: bitsPerSample)

        if let list = listChunk {
            header.append(list)
        }

        header.appendASCII("data")
        header.append(uint32LE: UInt32(dataBytes))

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

    /// Peak absolute amplitude across all samples. Used for the silence-skip threshold.
    static func peakAmplitude(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
        }
        return peak
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

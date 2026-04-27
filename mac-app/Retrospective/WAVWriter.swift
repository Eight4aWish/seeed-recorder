// Minimal 32-bit float WAV writer (WAVE_FORMAT_IEEE_FLOAT, format=3).
//
// Logic Pro, Ableton 11+, Pro Tools, and Audacity all read 32-bit float WAVs.
// We pick this over PCM int24 because:
//   1. The capture is already Float32 — no quantization on save.
//   2. Captured signal can briefly exceed 0 dBFS without clipping.
//
// Header layout (44 bytes total) for an N-channel float WAV:
//   "RIFF" | size-8        (8 bytes)
//   "WAVE"                  (4)
//   "fmt " | 16             (8)
//   formatTag=3 | numCh | sampleRate | byteRate | blockAlign | bitsPerSample=32  (16)
//   "data" | dataSize       (8)
//   <interleaved float32 samples>

import Foundation

enum WAVWriter {
    /// Write an N-channel 32-bit float WAV. `samples` is one Float32 array per channel,
    /// all the same length. Channels are interleaved into the file in input order.
    static func writeFloat32(
        url: URL,
        sampleRate: Double,
        channels: [[Float]]
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
        let riffBytes  = 36 + dataBytes        // "WAVE" + fmt chunk (24) + data header (8) = 36

        var header = Data()
        header.reserveCapacity(44)

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
}

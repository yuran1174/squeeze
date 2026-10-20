import Compression
import Foundation

/// Predicts how much compression will save without touching any file:
/// reads a sample of the files and compresses it in memory with LZFSE in 64 KiB blocks, like APFS does.
public enum Estimator {
    static let block = 64 * 1024

    /// Compressed/original ratio of a block of data, 0…1 (1 = does not compress).
    public static func ratio(of data: Data) -> Double {
        guard !data.isEmpty else { return 1 }
        var input = 0
        var output = 0
        var offset = 0
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: block + 4096)
        defer { dst.deallocate() }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < data.count {
                let n = min(block, data.count - offset)
                let written = compression_encode_buffer(dst, block + 4096, base + offset, n, nil, COMPRESSION_LZFSE)
                input += n
                output += (written == 0 || written >= n) ? n : written // incompressible blocks are stored as they are
                offset += n
            }
        }
        return input > 0 ? Double(output) / Double(input) : 1
    }

    /// Estimated bytes saved by compressing `files`. Reads at most `sampleBytes` spread across the files.
    public static func estimateSavings(of files: [FileItem], sampleBytes: Int64 = 96 << 20, perFile: Int = 4 << 20) -> Int64 {
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return 0 }
        let step = max(1, files.count / 300)
        var sampled = 0.0
        var compressed = 0.0
        var budget = sampleBytes
        for (i, f) in files.enumerated() where i % step == 0 {
            if budget <= 0 { break }
            guard let h = try? FileHandle(forReadingFrom: f.url) else { continue }
            let want = Int(min(Int64(perFile), budget, f.size))
            let data = (try? h.read(upToCount: want)) ?? nil
            try? h.close()
            guard let data, !data.isEmpty else { continue }
            sampled += Double(data.count)
            compressed += Double(data.count) * ratio(of: data)
            budget -= Int64(data.count)
        }
        guard sampled > 0 else { return 0 }
        return Int64(Double(total) * max(0, 1 - compressed / sampled))
    }
}

import Foundation
import NaturalLanguage

/// Embedding provider + binary quantization.
///
/// The index below is deliberately MODEL-AGNOSTIC. PASS-4 Area D picks
/// EmbeddingGemma-300M @ Q8 via MLX (Matryoshka-truncated to 256d) and explicitly warns
/// that Apple's NLEmbedding is a trap for a decades-long archive: 512 dims, a short
/// sequence limit, no MTEB submission, and — fatally — it is a moving target you do not
/// control, so Apple can invalidate every vector in a point release.
///
/// It is used here anyway, on purpose: it ships with the OS, so the retrieval pipeline
/// works today with zero downloads, and swapping in EmbeddingGemma changes ONE function.
/// That swap is cheap precisely because we keep the raw text forever — re-embedding a
/// decade is ~38 hours and $0.39 (Area D §9).
enum Embed {
    static let provider = "nlembedding.en.v1"

    private static let sentence: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// Full-precision vector for a piece of text.
    static func vector(_ text: String) -> [Double]? {
        guard let e = sentence else { return nil }
        let t = String(text.prefix(1000))          // provider has a short sequence limit
        if let v = e.vector(for: t) { return v }
        // sentence embedding returns nil for some inputs; fall back to a word-mean
        guard let w = NLEmbedding.wordEmbedding(for: .english) else { return nil }
        var acc = [Double](repeating: 0, count: w.dimension); var n = 0
        for tok in t.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let v = w.vector(for: String(tok)) {
                for i in 0..<acc.count { acc[i] += v[i] }; n += 1
            }
        }
        guard n > 0 else { return nil }
        for i in 0..<acc.count { acc[i] /= Double(n) }
        return acc
    }

    /// Binary quantization: sign of each dimension -> 1 bit.
    ///
    /// 32× smaller than fp32 while preserving ~96% of retrieval quality with a rescore
    /// step (Area D §7.1). At `bits = 256` this is **32 bytes per vector**, which is the
    /// number the whole index design rests on: 91M vectors = 2.9 GB.
    static func binarize(_ v: [Double], bits: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bits / 8)
        let n = min(bits, v.count)
        for i in 0..<n where v[i] > 0 {
            out[i >> 3] |= UInt8(1 << (7 - (i & 7)))
        }
        return out
    }

    static func embedBinary(_ text: String, bits: Int) -> [UInt8]? {
        vector(text).map { binarize($0, bits: bits) }
    }
}

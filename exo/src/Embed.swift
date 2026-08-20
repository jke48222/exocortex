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
    static let qwenProvider = "qwen3-emb-0.6b-4bit-dwq"

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


/// Out-of-process embedding via the MLX sidecar (`tools/embed_qwen3.py`).
///
/// Qwen3-Embedding-0.6B, Apache-2.0. PASS-4 Area D ranked EmbeddingGemma first and called
/// this "a genuinely close call"; Qwen3 wins on a practical point the research flagged —
/// the Gemma weights are license-gated on HuggingFace, Apache-2.0 is not.
///
/// Binary quantization happens Python-side so only 32 B/vector crosses the boundary, and
/// packbits is MSB-first to match `Embed.binarize`.
enum Chunker {
    /// Sliding-window chunking. The unit of retrieval must be a passage, not a document:
    /// a 20,000-char transcript truncated to its first 1,000 chars produces a vector that
    /// never saw the text you are searching for. Measured directly — `arcminute` sat at
    /// char 19,410 of a 20,000-char doc and was invisible to whole-doc embedding.
    static func chunks(_ text: String, size: Int = 900, overlap: Int = 200) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > size else { return t.isEmpty ? [] : [t] }
        var out: [String] = []
        let chars = Array(t)
        var i = 0
        let step = max(1, size - overlap)
        while i < chars.count {
            out.append(String(chars[i..<min(chars.count, i + size)]))
            if i + size >= chars.count { break }
            i += step
            if out.count >= 40 { break }        // cap pathological documents
        }
        return out
    }
}

enum EmbedMLX {
    struct Result { let id: Int64; let vec: [UInt8]; let i8: [Int8] }

    static func scriptPath() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        // build/ -> exo/ -> tools/
        return exe.deletingLastPathComponent()
            .appendingPathComponent("tools/embed_qwen3.py").path
    }

    /// A LONG-LIVED sidecar process.
    ///
    /// The first version spawned Python per batch. Model load is ~6s, so at 64 events a
    /// batch a 60k-event corpus spent hours doing nothing but re-loading weights — the
    /// job ran for an hour and produced zero vectors. Keeping one process alive for the
    /// whole run pays that cost exactly once.
    final class Session {
        private let p = Process()
        private let inPipe = Pipe(), outPipe = Pipe()
        private var reader: FileHandle { outPipe.fileHandleForReading }
        private var pending = Data()
        private(set) var ok = false

        init?(bits: Int) {
            let script = EmbedMLX.scriptPath()
            guard FileManager.default.fileExists(atPath: script) else { return nil }
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-u", script, "--bits", String(bits)]  // -u: unbuffered
            p.standardInput = inPipe; p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            ok = true
        }

        /// Read exactly one newline-terminated line, blocking.
        private func readLine() -> String? {
            while true {
                if let r = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<r]
                    pending.removeSubrange(pending.startIndex...r)
                    return String(decoding: line, as: UTF8.self)
                }
                let chunk = reader.availableData
                if chunk.isEmpty { return nil }
                pending.append(chunk)
            }
        }

        func embed(_ items: [(Int64, String)]) -> [Result] {
            guard ok, !items.isEmpty else { return [] }
            // Write on a background thread. A pipe buffer is ~64 KB; a batch of chunks is
            // far larger, so writing it all before reading deadlocks — we block filling
            // stdin while the sidecar blocks filling stdout that nobody is draining.
            let w = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                for (id, text) in items {
                    let obj: [String: Any] = ["id": id, "text": text]
                    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { continue }
                    w.write(d); w.write(Data([0x0A]))
                }
                if let e = try? JSONSerialization.data(withJSONObject: ["cmd": "end"]) {
                    w.write(e); w.write(Data([0x0A]))
                }
            }
            // Frame the batch with an explicit end marker. Counting replies is fragile:
            // any input the sidecar declines to answer leaves the reader blocked in
            // read(2) forever, because availableData blocks rather than returning EOF
            // while the child is alive. Confirmed by sampling a hung process.
            var out: [Result] = []
            while let line = readLine() {
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                else { continue }
                if o["end"] != nil { break }
                guard let id = (o["id"] as? NSNumber)?.int64Value else { continue }
                guard let hex = o["hex"] as? String else { out.append(Result(id: id, vec: [], i8: [])); continue }
                func unhex(_ h: String) -> [UInt8] {
                    var b = [UInt8](); b.reserveCapacity(h.count / 2)
                    var i = h.startIndex
                    while i < h.endIndex, let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex) {
                        b.append(UInt8(h[i..<j], radix: 16) ?? 0); i = j
                    }
                    return b
                }
                let i8 = (o["i8"] as? String).map { unhex($0).map { Int8(bitPattern: $0) } } ?? []
                out.append(Result(id: id, vec: unhex(hex), i8: i8))
            }
            return out
        }
        func close() {
            try? inPipe.fileHandleForWriting.close()
            p.terminate()
        }
    }

    /// One-shot convenience (used for single query embeddings).
    static func embed(_ items: [(Int64, String)], bits: Int) -> [Result] {
        guard let s = Session(bits: bits) else { return [] }
        defer { s.close() }
        return s.embed(items)
    }
}

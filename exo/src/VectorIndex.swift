import Foundation
import Dispatch

/// Flat binary vector index, scanned by brute force.
///
/// PASS-4 Area D §7.2 makes a deliberately contrarian call: at life scale you may need no
/// ANN index at all. 91M vectors × 32 B = 2.9 GB, and a binary scan is XOR + popcount —
/// pure SIMD, perfectly sequential, memory-bandwidth-bound. Shipping without an ANN index
/// removes an entire category of index-corruption, rebuild and format-obsolescence risk
/// from a system meant to last 30 years.
///
/// That estimate was marked [Medium] — "a bandwidth calculation, not a measured benchmark.
/// Measure before committing." `exo bench` is that measurement.
struct VectorIndex {
    let bits: Int
    var stride: Int { bits / 8 }
    private(set) var data: [UInt8] = []
    private(set) var ids: [Int64] = []

    init(bits: Int) { self.bits = bits }

    mutating func add(id: Int64, vector: [UInt8]) {
        precondition(vector.count == stride)
        ids.append(id); data.append(contentsOf: vector)
    }
    mutating func reserve(_ n: Int) { data.reserveCapacity(n * stride); ids.reserveCapacity(n) }
    var count: Int { ids.count }

    /// Hamming top-k. Returns (id, distance) ascending.
    func search(_ query: [UInt8], k: Int) -> [(Int64, Int)] {
        precondition(query.count == stride)
        let words = stride / 8
        var best: [(Int64, Int)] = []
        best.reserveCapacity(k + 1)
        var worst = Int.max

        query.withUnsafeBytes { qraw in
            let q = qraw.bindMemory(to: UInt64.self)
            data.withUnsafeBytes { draw in
                let d = draw.bindMemory(to: UInt64.self)
                for i in 0..<ids.count {
                    let base = i * words
                    var dist = 0
                    for w in 0..<words { dist &+= (d[base &+ w] ^ q[w]).nonzeroBitCount }
                    if best.count < k || dist < worst {
                        // small-k insertion sort; k is 8-50 in practice
                        var j = best.count
                        best.append((ids[i], dist))
                        while j > 0 && best[j - 1].1 > dist { best.swapAt(j, j - 1); j -= 1 }
                        if best.count > k { best.removeLast() }
                        worst = best.last?.1 ?? Int.max
                    }
                }
            }
        }
        return best
    }

    /// Parallel scan across cores. The single-threaded version measured 17.4 GB/s on an
    /// M5 Pro — nowhere near the chip's aggregate bandwidth, because one core cannot pull
    /// it. Sharding across performance cores is what makes the no-ANN design viable.
    func scanOnlyParallel(_ query: [UInt8], shards: Int) -> Int {
        let words = stride / 8
        let n = ids.count
        guard n > 0 else { return 0 }
        let per = (n + shards - 1) / shards
        let partials = UnsafeMutablePointer<Int>.allocate(capacity: shards)
        partials.initialize(repeating: 0, count: shards)
        defer { partials.deallocate() }

        query.withUnsafeBytes { qraw in
            let q = qraw.bindMemory(to: UInt64.self)
            data.withUnsafeBytes { draw in
                let d = draw.bindMemory(to: UInt64.self)
                DispatchQueue.concurrentPerform(iterations: shards) { s in
                    let lo = s * per, hi = min(n, lo + per)
                    if lo >= hi { return }
                    var acc = 0
                    for i in lo..<hi {
                        let base = i * words
                        var dist = 0
                        for w in 0..<words { dist &+= (d[base &+ w] ^ q[w]).nonzeroBitCount }
                        acc &+= dist
                    }
                    partials[s] = acc
                }
            }
        }
        var total = 0
        for s in 0..<shards { total &+= partials[s] }
        return total
    }

    /// Raw scan with no top-k bookkeeping — isolates pure memory-bandwidth throughput.
    func scanOnly(_ query: [UInt8]) -> Int {
        let words = stride / 8
        var acc = 0
        query.withUnsafeBytes { qraw in
            let q = qraw.bindMemory(to: UInt64.self)
            data.withUnsafeBytes { draw in
                let d = draw.bindMemory(to: UInt64.self)
                for i in 0..<ids.count {
                    let base = i * words
                    var dist = 0
                    for w in 0..<words { dist &+= (d[base &+ w] ^ q[w]).nonzeroBitCount }
                    acc &+= dist
                }
            }
        }
        return acc
    }
}

/// Reciprocal Rank Fusion, k = 60 (Cormack, Clarke & Büttcher, SIGIR 2009).
///
/// Chosen over weighted score fusion for one reason: BM25 scores and cosine similarities
/// live on incomparable, non-stationary scales, so weighting requires knowing the score
/// distribution — which changes every time you swap embedding model. RRF reads only RANKS,
/// so it survives a model migration untouched. For a system meant to outlive several
/// embedding models, scale-invariance beats the last 2% of nDCG.
enum RRF {
    static func fuse(_ rankings: [[Int]], k: Double = 60) -> [(Int, Double)] {
        var score: [Int: Double] = [:]
        for list in rankings {
            for (i, id) in list.enumerated() { score[id, default: 0] += 1.0 / (k + Double(i + 1)) }
        }
        return score.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}

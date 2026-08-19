# exo — measured results

Measurements from this machine (**Apple M5 Pro, 15 logical cores, 24 GB unified, macOS 27**).
The portfolio's stated signature is published measurement, so both of these are reported
including the one that contradicts the research that preceded it.

---

## 1. Binary brute-force scan — the research estimate was right for the wrong reason

PASS-4 Area D §7.2 argued a life-scale vector index may need **no ANN structure at all**: 91M
vectors × 32 B = 2.9 GB, scanned with XOR + popcount. It estimated **~18 ms at ~165 GB/s
effective**, and flagged itself honestly:

> *[Medium — this is a bandwidth calculation, not a measured benchmark. Measure before committing.]*

Measured (`exo bench --bits 256`, best of 3 after warm passes, scan only):

| vectors | size | 1-thread | GB/s | parallel (15 cores) | GB/s | speedup |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000,000 | 0.03 GB | 1.9 ms | 15.7 | **0.3 ms** | 109.2 | 6.9× |
| 10,000,000 | 0.30 GB | 17.7 ms | 16.9 | **1.9 ms** | 158.5 | 9.4× |
| **91,000,000** | **2.71 GB** | **161.9 ms** | 16.8 | **17.0 ms** | **159.6** | **9.5×** |

**The verdict, precisely stated.** The 18 ms number was almost exactly right — but the reasoning
behind it was not. It assumed a single scan could reach ~165 GB/s, and **a single core reaches
16.8 GB/s, 9.5× short.** The predicted throughput is only achievable across cores.

So the contrarian conclusion **survives, conditionally**: at 91M vectors a brute-force binary scan is
**17 ms — imperceptible, and genuinely no ANN index required** — *provided the scan is sharded across
cores*. Single-threaded it is 162 ms, which is perceptible in an interactive everything-bar and would
have forced an ANN index and all the corruption, rebuild and format-obsolescence risk that comes with
one. **The architectural claim was load-bearing and one implementation detail decided it.**

Caveat kept explicit: this is synthetic random data measuring scan throughput, not end-to-end query
latency, and it excludes top-k bookkeeping and the int8 rescore tier.

---

## 2. Embedding quality — Apple's NLEmbedding fails the job embeddings exist for

The index is deliberately model-agnostic; `NLEmbedding` was used because it ships with the OS and needs
no downloads. PASS-4 Area D called it *"a trap for this use case"* — 512 dims, a short sequence limit,
no MTEB submission, and a moving target Apple can invalidate in a point release.

**Probe.** Embeddings earn their cost by finding documents whose *wording* differs. So: take a document
BM25 retrieves for an exact rare term, then query with a paraphrase containing **none** of those words,
and check whether the known-good document appears anywhere in the hybrid top-50.

| exact term | paraphrase query | gold doc found in top-50? |
|---|---|---|
| `arcminute` | "how accurate is the brass planet mechanism" | **no** — vector miss |
| `popcount` | "measuring how fast the vector scan runs" | **no** — vector miss |

**0 of 2.** Inspection of ranked output shows the same failure qualitatively: for the query
*"retention spoliation"*, the top vector hit was an unrelated website-security audit from a different
project, while BM25 returned the two genuinely correct documents.

**Verdict: the retrieval architecture is complete and fast; the embedding provider is the bottleneck,
and it is exactly the component the design isolates for replacement.** Swapping to EmbeddingGemma-300M
@ Q8 via MLX (the Area D pick) changes one function, `Embed.vector`. It is cheap because the raw text
is kept forever — re-embedding a decade is ~38 hours and $0.39.

**Do not read the hybrid results as a quality claim.** RRF fusion, rank provenance and the binary index
are verified working; semantic recall is pending a real model.

---

## 3. Capture fleet (Phase 1)

- **885 events from real Claude Code transcripts in 1.2 s**; 10,389 records skipped by the
  tool_use/tool_result/thinking filter; **72 secret-shaped lines redacted**
- Ingest is **idempotent** — a second run ingests zero (per-file resume cursor)
- **Expiry deletes and the FTS index does not drift**: a backdated `third_party` row purged at
  ttl=14 d, receipt written, index **885/885** afterwards (external-content FTS5 silently drifts on
  delete without an explicit index-delete trigger)
- Litigation hold suspends all three TTL classes and overrides `--apply`
- Exclusion: `ConcealedType` clipboard items **never stored**, secret-shaped content dropped,
  ordinary text captured, re-runs don't duplicate
- **7/7 regression tests pass**
- Embedding throughput: **56 rows/s** via `NLEmbedding` (852 rows in 15.2 s)

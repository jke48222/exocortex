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

## 2. Embedding quality — three rounds, and the bottleneck moved twice

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

### Round 2 — the real model, and a bug the probe exposed

MLX 0.32.1 + **Qwen3-Embedding-0.6B-4bit-DWQ** (Apache-2.0; chosen over the Area D pick
EmbeddingGemma because Gemma's weights are **license-gated on HuggingFace** and Apache-2.0 is not).

At the unit level the model is unambiguously good — Hamming distance from *"how accurate is the brass
planet mechanism"*: **63 to an orrery sentence, 84 to sourdough, 87 to a popcount sentence.** Correct
ordering, clear margin.

**But end-to-end it still scored 0/3.** The cause was not the model:

| gold term | document length | term appears at char |
|---|---:|---:|
| `arcminute` | 20,000 | **19,410** |
| `popcount` | 20,000 | **11,882** |
| `spoliation` | 2,661 | **1,419** |

**Every match sat beyond the 1,000-char embedding window. The vector never saw the text being searched
for.** Whole-document embedding is the wrong unit of retrieval — which PASS-4 Area D §9 already said
("sane chunking, 5-minute semantic segments"), and which was simply not implemented.

Fixed with a sliding-window chunker (900 chars, 200 overlap, one vector per chunk, over-fetch then
collapse chunks back to their parent event). A 17,340-char document now yields 25 vectors; the corpus
went from 885 vectors to **2,112 over 885 events**.

### Round 3 — chunked, and the honest number

| probe | 256-bit | 1024-bit |
|---|---|---|
| `arcminute` ← "how accurate is the brass planet mechanism" | miss | miss |
| `popcount` ← "measuring how fast the vector scan runs" | **vec#44** | **vec#25** |
| `spoliation` ← "deleting records after a lawsuit starts is a problem" | miss | miss |

**Width is not the constraint.** 1024-bit costs 4× the storage (128 B/vec; 11.6 GB at 91M vs 2.9 GB)
and buys one rank improvement, not a fix.

The strict gold-document metric is also too harsh — for a *paraphrase* query the best answer may
legitimately be a different document. On the looser topical measure, **2 of the top 6 vector hits for
the orrery paraphrase were genuinely relevant.** Weak but clearly nonzero.


---

## ⚠️ CORRECTION — Round 4's conclusion was wrong, and the cause was the evaluation

Round 4 below concluded *"the int8 rescore tier consistently makes retrieval WORSE and I could not fix
it."* **That conclusion is retracted. The rescore tier works; the probe measuring it did not.**

Two defects in the evaluation, both mine:

1. **Ranks were compared across different databases.** The "full-precision ceiling ranks it 1/2015"
   figure came from one DB, the pipeline numbers from another, ingested over a different window with
   different `seq` numbering — so they referred to *different gold documents*. Re-run apples-to-apples
   on the same stored vectors, Python scored the gold at rank 41 and Swift at 29. **Swift was never
   behind Python; there was no discrepancy to explain.**
2. **The gold documents were meta-commentary.** "Gold" was defined as whichever document BM25 ranked
   first for a rare term — but the corpus is a transcript of *building this system*, so the top hit for
   `arcminute` was a **230-character message whose entire text reads "At full precision `arcminute`
   ranks 1 of 2015"**. The probe was retrieving the experiment's own notes, not documents about
   orreries. Any conclusion drawn from it was unsound.

### The controlled eval

`tests/retrieval_eval.py` — 20 authored documents on distinct topics, 20 paraphrase queries sharing
minimal vocabulary with their target, ground truth known by construction rather than inferred.

| width | method | Recall@1 | Recall@5 | MRR |
|---|---|---:|---:|---:|
| — | BM25 (lexical baseline) | 0.55 | 0.65 | 0.634 |
| 256-bit | binary | 0.80 | 1.00 | 0.875 |
| 256-bit | **binary + rescore** | **0.85** | 1.00 | 0.925 |
| 512-bit | binary | 0.85 | 1.00 | 0.917 |
| 512-bit | **binary + rescore** | **0.90** | 1.00 | 0.950 |
| 1024-bit | binary | 0.85 | 1.00 | 0.917 |
| 1024-bit | **binary + rescore** | **0.95** | 1.00 | 0.975 |

**Three conclusions, now on solid ground:**

- **Vector retrieval decisively beats lexical on paraphrase queries** — 0.85 vs 0.55 Recall@1. This is
  the value proposition embeddings exist for, and it is real.
- **The rescore tier helps at every width**, +0.05 to +0.10 Recall@1 and +0.05 MRR, exactly as Area D
  §7.1 predicted. It is re-enabled by default.
- **Width helps monotonically but with diminishing returns**: 256→1024 buys +0.15 Recall@1 with
  rescore, at 4× the storage (32 B → 128 B per vector; 2.9 GB → 11.6 GB at 91M). **256-bit + rescore
  (0.85) matches 1024-bit binary-only (0.85) at a quarter of the space** — so the Area D pairing of a
  narrow binary tier *with* a rescore is the efficient point, and my earlier "binary@256d doesn't hold
  for this model" was measuring 256-bit *without* the rescore it was always specified to have.

**The lesson worth keeping.** Every number in the retracted round was real; the code did what I said it
did. The failure was that "gold document" was inferred from the system under test instead of authored
independently — which is precisely the flaw PASS-4 Area A identified in LoCoMo (6.4% wrong answer key,
a judge accepting 63% of wrong answers). **I reproduced the exact methodological failure my own
research had catalogued**, and it produced a confident, wrong, three-commit conclusion. An eval whose
ground truth comes from the thing being evaluated is not an eval.

---

### Round 4 — the retracted round, kept for the record

The gap identified above was built. It did **not** help, and three fixes did not change that.

**First, the ceiling.** Full-precision cosine over all 2,015 chunks in Python, outside the Swift
pipeline entirely:

| probe | gold event's best-chunk rank, full float |
|---|---:|
| `arcminute` | **1 / 2015** |
| `popcount` | 166 / 2015 |
| `spoliation` | 235 / 2015 |

**`arcminute` ranks first.** So the model, the chunking and the corpus are jointly capable of a perfect
answer, and any shortfall from here is the pipeline's, not the model's. Note also that `popcount` and
`spoliation` are weak *even at the ceiling* — for a paraphrase query the strict gold document is
sometimes simply not the best semantic answer, so those two probes are partly measuring the metric.

**Then the measured matrix:**

| probe | 256+rescore | 1024 binary | 1024+rescore | ceiling |
|---|---|---|---|---|
| `arcminute` | miss | **vec#16** | vec#29 | 1/2015 |
| `popcount` | vec#39 | **vec#14** | vec#46 | 166/2015 |
| `spoliation` | miss | miss | miss | 235/2015 |

Two findings and one failure:

**1. Binary @256d does not hold up for this model — and that contradicts the Area D recommendation.**
The 256-bit headline was calibrated on EmbeddingGemma, which is explicitly Matryoshka-trained
("highest Task Mean scores in its class even at 128 dims"). Qwen3-Embedding-0.6B truncated to 256 of
1024 dims, then binarized, then run from 4-bit DWQ weights, stacks three lossy steps and loses the
answer entirely (`arcminute`: miss at 256, vec#16 at 1024). **The recommendation is model-specific and
was applied to the wrong model.** Default width is now 1024.

**2. The int8 rescore tier consistently makes retrieval WORSE, and I could not fix it.**
Three defects were found and corrected, and none changed the outcome:
- the index keyed every chunk by its parent `seq`, making a document's chunks indistinguishable and
  silently collapsing the shortlist — fixed by chunk-addressing the index
- scoring used a raw integer dot product, which favours high-magnitude vectors after int8 rounding —
  fixed by using cosine
- the shortlist was under-fetched — fixed by `--rescore N` over-fetch

After all three, `arcminute` still goes **vec#16 → vec#29** when the rescore is enabled. This is
backwards: the rescore signal is exactly what scores rank 1 at the ceiling, so a correct
implementation should approach it, not retreat from it. **The defect is real, unexplained, and not
yet found.** `--rescore` therefore defaults to **0 (off)**, because shipping a stage that measurably
degrades results would be worse than not shipping it.

**Status after the correction: retrieval works.** Chunking, binary scan, int8 rescore, RRF fusion,
rank provenance, and 17 ms at 91M vectors are all verified — the rescore against a controlled eval.
What was 'unclosed' was an artefact of the broken probe.

### The original gap statement — kept for the record

**Binary-only search is shipped; the rescore tier is not.** Area D §7.1 is explicit that binary
quantization preserves ~96% of retrieval quality **only with a rescore step** — retrieve
`rescore_multiplier × k` candidates by Hamming, then re-rank that shortlist against int8 or float
vectors. The design called for exactly two tiers (binary @256d for the scan, int8 @256d mmap'd for the
rescore) and **only the first is built.** Searching on 1-bit-per-dimension distances alone and
expecting full quality was never the plan; it is the most likely explanation for the remaining gap,
and it is the next thing to build.

**Do not read the current hybrid numbers as a quality ceiling.** Verified working: chunking, RRF
fusion, rank provenance, the binary index, and the 17 ms parallel scan. Not yet built: the rescore
tier. Quality should be re-measured after it exists, not before.

### Throughput

| provider | rows/s | note |
|---|---:|---|
| `NLEmbedding` (built-in) | 56 | fails the paraphrase test |
| Qwen3-0.6B-4bit via MLX, unchunked | 41 | |
| Qwen3-0.6B-4bit via MLX, chunked | 9–19 | ~2.4 vectors per event |

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

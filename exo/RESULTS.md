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


---

## 5. Ingesting a real corpus — three findings

Running the fleet against real data (91,384 events across six sources) surfaced things the
synthetic tests could not.

### 5.1 The `attributedBody` tail is not a tail — it is the future

The Phase-1 build skipped iMessage rows whose `text` is NULL, on the measured basis that they
were **5.6% of all history** and that a wrong body is worse than a missing one. Both halves
were wrong once broken down **by year**:

| year | messages | need typedstream |
|---|---:|---:|
| 2026 | 44,934 | **29.1%** |
| 2025 | 73,350 | 0.7% |
| 2024 | 57,537 | 0.1% |
| 2023 | 55,146 | 0.1% |

**Apple migrated to `attributedBody` in 2026.** The aggregate 3.8% figure averages a solved
past with an unsolved present, and the unsolved fraction is heading toward 100%.

And the parser was never as hard as the first attempt suggested. A naive NSString regex
recovered 13 of 40 blobs (32%); a correct **length-prefixed** read — one byte, or `0x81`
followed by a little-endian UInt16 — recovers, over 3,000 recent blobs:

- **95.1% parse successfully**
- **88.9% yield real text**
- 6.2% are attachment-only: a bare **U+FFFC Object Replacement Character**, i.e. a photo or
  file transfer with genuinely no text to recover — not a failure
- 4.9% fail

**Result: +31,328 messages recovered**, taking iMessage from 26,719 to 58,047 rows. No GPL
dependency and no subprocess — about forty lines.

### 5.2 A resume cursor hides its own past mistakes

Re-running ingest after fixing the parser recovered **one** message. Ingest resumes from
`max(ts)`, so it never revisits rows an older parser skipped. Any extraction improvement is
invisible to a system that only ever moves forward. Added `--rescan` to ignore the cursor;
re-inserting is safe because the unique index on `(source, external_id)` absorbs duplicates.
**This applies to every source, not just iMessage.**

### 5.3 Embedding throughput is 50× short of usable — and it is not a hang

Three separate stalls were diagnosed here, and only the first two were bugs:

1. **Model reloaded per batch.** The sidecar was spawned per 64 events; at ~6 s to load
   weights, a 60k corpus spent hours doing nothing else. Fixed with a persistent session.
2. **A silently-dropped reply blocks the reader forever.** The sidecar skipped blank inputs
   without emitting anything, while Swift read until it had one reply per input.
   `FileHandle.availableData` *blocks* rather than returning EOF while the child is alive, so
   one missing line hangs indefinitely. Confirmed by `sample`-ing the stuck process:
   `Session.embed → availableData → read`. Fixed twice over — the sidecar now emits exactly
   one line per input, **and** batches are framed by an explicit end marker so the reader
   never has to guess how many replies are coming.
3. **The remaining problem is not a hang at all.** The sidecar sits at 11–17% CPU — low
   because MLX runs on the GPU — and progress only becomes visible at batch commit. Measured
   honestly: **333 vectors in 362 s ≈ 0.92 vectors/s**, which is **~76 hours** for the full
   corpus.

**Cause:** the sidecar runs **one forward pass per chunk**. For a 0.6B model, Python
round-trip and MLX graph-evaluation overhead dominate the arithmetic. **Fix:** tokenize and
pad N texts and run a single batched forward pass — a contained change to `embed_qwen3.py`,
and the next thing to do here. Until then, semantic search is limited to whatever subset has
been embedded; **FTS5/BM25 works across the whole corpus regardless**, which is what the
everything-bar uses.

---

## 6. Contradiction detection — the filter the research specified does not exist here

PASS-4 Area E's pipeline is *SQL candidates → **DeBERTa NLI filter** → LLM four-way
classification → human confirmation*. There is no DeBERTa on this machine, and the substitute
question — can an embedding stand in for an entailment model? — has a clean answer.

### 6.1 `NLEmbedding` cannot filter belief pairs, at any threshold

The obvious substitute ships with the OS and is already linked. Cosine similarity on labelled
pairs:

| pair type | `NLEmbedding` (512d) | Qwen3 float (1024d) | **Qwen3 int8 (256d)** | Qwen3 binary (256d) |
|---|---:|---:|---:|---:|
| contradictory, same topic | −0.13 … 0.13 | 0.62 … 0.69 | **0.69 … 0.75** | 0.47 … 0.52 |
| same topic, different scope | 0.01 | 0.57 | **0.60** | 0.40 |
| near-duplicate | 0.24 … 0.57 | 0.98 | **0.98** | 0.91 |
| unrelated | −0.26 … −0.19 | 0.40 … 0.48 | **0.43 … 0.46** | 0.16 … 0.39 |
| **margin (lowest keep − highest drop)** | **none** | 0.090 | **0.135** | 0.007 |

**`NLEmbedding` places real contradictions inside the unrelated range.** No threshold separates
them, so it is not a matter of tuning. This is the same provider Area D called *"a trap"*, and
§2 above already found it fails the paraphrase test — this is the second independent failure.

**The surprise is the int8 column.** The rescore tier built for retrieval separates *better than
full float* — 0.135 vs 0.090 — because truncating 1024 dims to 256 drops dimensions that add
noise on single sentences. The **binary** tier at the same width is unusable here (0.007 margin;
it collapses the scope case onto unrelated), even though §2's controlled eval shows binary+rescore
at 0.85–0.95 Recall@1 for *retrieval*. **Same vectors, same widths, opposite verdict — the
quantization that is right for ranking documents is wrong for comparing two sentences.**

Band shipped: **0.55 ≤ cos ≤ 0.95** on int8@256. Below is unrelated; above is a near-duplicate,
which is not a disagreement.

### 6.2 The on-device model will not call anything a contradiction

Fixture: 8 elicited beliefs → 28 interval-overlapping pairs → 14 survive the band. One pair is a
head-on contradiction by construction (*"I work best completely alone with nobody else around"* /
*"I do my best work surrounded by other people in a room"*).

| prompt | genuine_change | scope_difference | head-on pair found? |
|---|---:|---:|---|
| four-way, one free-text discriminator | 0 | 14 | **no** — `discriminator: "work environment"` |
| four-way, discriminator split into situation A and situation B | 0 | 14 | **no** — `A: "working alone" / B: "working with others"` |
| **framing call separated from judging call, + question identity** | **1** | 13 | **yes** |

Two failure modes, and the second is the interesting one:

1. Given one free-text field for "what separates these", the model writes **the topic the two
   statements share** — "work environment" — and calls that a scope. 
2. Forced to name situation A and situation B separately, it restates **each statement as its own
   situation**. That is a tautology available for any pair whatsoever, so it never runs out.

No wording fixed either. What worked was to stop asking the model to judge and ask it to
*describe*: for each statement alone, what question about the person does it answer? On the
head-on pair it writes **the identical sentence twice** — *"What is the best environment for the
person to work in"* — and then, asked separately, still rules the two compatible. **The
decomposition is sound; only the judgement is broken**, so the judgement is done in code:
two statements answering the same question with different answers contradict by definition.

### 6.3 The judgement contaminates the description if one call does both

Folding `questionA`/`questionB` into the four-way schema looked free. It is not:

| how the questions were asked | question similarity on the head-on pair |
|---|---:|
| inside the four-way prompt | 0.830 — below threshold, test never fires |
| **its own call, describe-only instructions** | **1.000** |

Asked alongside the verdict, the model writes questions that already contain the verdict
("…when working with others"). **Describing has to be the model's only job for the description to
be worth anything.**

### 6.4 What the identity test buys, stated as precision and recall

Question similarity on a labelled set:

| labelled | question similarity |
|---|---:|
| changed mind, same question | **1.000** ← caught |
| changed mind, reframed (*"I don't drink anymore"* / *"I enjoy a glass of wine most evenings"*) | 0.556 ← **missed** |
| genuine scope difference | 0.746, 0.829 |
| unrelated | 0.583, 0.789 |

Only identity separates, and it separates by a mile — 1.000 against a next-highest of 0.829.
Everything below overlaps and keeps the model's own verdict. Threshold 0.95.

**P = 1.0, R = 0.5** on this set: on the 8-belief fixture it surfaced exactly one pair, the right
one, with no false positives. That is deliberately the shape Area E asks for — *"false positives
destroy it — tune to P ≈ 0.9 even at R = 0.5"* — and half of real contradictions go unfound.
**The missing half is what the DeBERTa NLI stage would buy.** The labelled set is 6 pairs; these
are direction-of-effect numbers, not a benchmark.

On the **real ledger** (3 confirmed beliefs, 3 pairs): 2 unrelated, 1 near-duplicate, **0
contradictions** — correct, and the near-duplicate is a genuine finding (two `exo tell` records of
the same belief about wanting a digital brain).

### 6.5 Two bugs the fixture found in shipped code

- **`claim_id` did not include the claim's text.** The content address hashed
  `(subject, predicate, object, polarity, scope)` — and elicitation writes every answer as
  `(me, states, NULL, +1, NULL)`. Every belief ever recorded by `exo tell` or `exo ask` therefore
  hashed to **one row**, and `INSERT OR IGNORE` kept the first text, so later beliefs silently
  pointed at the wrong sentence. Masked until now only because `exo ask` was filing the interview
  question in `scope`, which happened to make the hashes differ. Fixing that (below) would have
  triggered it immediately.
- **`exo ask` wrote the interview question into `claim.scope`.** Scope means the situation a
  belief holds *in*, and `scope_difference` is one of the four verdicts — so the detector would
  have read the interview script as evidence that nothing ever conflicts. The question now lives
  in `belief.elicited_by`.

`ledger-test` was also found red (6 checks, 1 failing) and had been since the review gate landed:
it asserts a re-extraction rewrites history, but records that re-extraction as `model_selfreport`,
which `exo beliefs` deliberately hides. Both suites now wipe their fixtures at **both** ends —
synthetic P / not-P pairs left in the real ledger are exactly what this feature is built to find.

### 6.6 `availability` lies, and the failure is silent

Sustained use put the machine into a state where **every** `respond()` failed instantly:

```
SensitiveContentAnalysisML error 15
  → CombinedTextSanitizerBackend.BackendError 1
    → ModelManagerServices.ModelManagerError 1013
```

That is the text sanitizer every request is screened by, not the language model. It latches
**system-wide** — a freshly built binary hit it on its first call, in 0.0 s — and
`SystemLanguageModel.default.availability` answers `.available` throughout, so the guard at the
top of the function cannot see it.

Left alone, a scan spent **333 s** failing 14 times and printed `0 judged`, which reads exactly
like a quiet ledger. Both `scan` and `extract` now abort after 3 consecutive failures with the
error text, in ~4 s, and say in as many words that this is **not** a clean bill of health. A stage
that fails closed and stays quiet is indistinguishable from a clean ledger, which is the one lie
this feature cannot afford to tell.

---

## 7. Connection discovery — similarity finds the corpus's hubs, and its hubs are its boilerplate

S5 is the stage Area F calls "the whole ballgame". Stage 1 is fast and works as specified:
**46,194 chunk-neighbour pairs from 500 anchors in 0.7 s.** Everything interesting happened
in what came out of it.

### 7.1 The first twelve findings were twelve pieces of infrastructure

| rank | sim | what it connected |
|---:|---:|---|
| 1 | 0.911 | a Claude.ai sign-in **email** ↔ the Claude.ai sign-in **URL** |
| 2 | 0.890 | the same email ↔ the same URL with a `state=` parameter |
| 3–6 | 0.87–0.83 | four marketing emails ↔ `Base directory for this skill: /private/tmp/…` |
| 7 | 0.862 | a Drive share notification ↔ the Drive folder URL |

**None of Area F's filters touch this, and none of them can.** A login email and a login URL
genuinely are different sources, genuinely 142 days apart, genuinely about one thing. The
candidates were not wrong — *the assumption that similarity plus distance implies meaning was*.
A life-log's most-connected documents are the ones it contains hundreds of copies of.

### 7.2 What is actually in the corpus

| source | vectorized events | eligible after filtering | why |
|---|---:|---:|---|
| `browser.*` | 21,616 | **0** | **21,523 (99.6%) are a bare URL.** A third of the whole index |
| `gmail` | 3,315 | 1,212 | 34% carry U+034F marketing padding, 31% "unsubscribe", 17% `utm_` |
| `claudecode` | 8,042 | 4,259 | repeated scaffolding: `[Request interrupted by user]` ×59, `<local-command-caveat>` ×45 |
| `imessage` | 17,527 | 507 | 189 events are from 5–6 digit **short codes**, i.e. businesses |

**88% of the vectorized corpus is ineligible to be one end of a connection.** This is the belief
extractor's lesson in a different costume — there, 141 of the first 145 claims were task
directives. The corpus does not contain what you assume in the proportions you assume.

Two filters generalize past this corpus and are worth keeping:

- **Hub suppression.** A document that is the nearest neighbour of more than *k* different
  anchors is a hub, not a memory — document frequency applied to neighbours. Unlike a pattern
  list it keeps working on boilerplate nobody has catalogued yet.
- **Structure over substrings.** `looksAutomated` tests a *run* of invisible padding
  characters, mixed-script homoglyphs, and URL density. The substring list kept losing: it
  excluded U+034F and missed **501 rows padded with U+200C and 48 with U+200B**, and LinkedIn
  hides "unsubscribe" at character **4,068 of 5,272**, past any truncated prefix.

### 7.3 Two Swift bugs that made the filter silently useless

- **`Character` iteration cannot see a ZWNJ.** Swift strings iterate as grapheme clusters, and
  U+200C / U+200D are precisely the scalars whose job is to *glue a cluster together* — so
  `Set<Character>` membership never matched, and every padded mail passed. `unicodeScalars` fixes
  it. Confirmed against the bytes: `E2808C 20 E2808C 20 …`.
- **Testing a truncated prefix.** Groundedness and automation were both checked against the
  600-character display copy. 38 of 40 links were marked ungrounded, including `IDEA EXPEDITION`
  and `content/site.json`, which are in the notes — just not in the first 600 characters.

### 7.4 The model confabulates the link 95% of the time, and an escape hatch did not help

| what the model was asked | result |
|---|---|
| "what do these have in common, in one sentence" | bare categories: `work`, `the condition`, `the remote`, `Mark` |
| "name the ONE specific thing, copied word for word" | **38 of 40 confabulated.** Verified directly: `content/site.json` and `Turbopack` each occur in note B and **nowhere** in note A |
| the same, plus a `sharesSomethingSpecific: Bool` it could set false | **used it 0 times out of 39** |

That last row is a **negative result against Area F**, which expects an `unsupported_fields`
escape hatch to *"measurably reduce confabulation by giving the model a licensed place to admit
uncertainty."* Given the licensed place, in the schema and not merely in the prose, this model
never took it.

**So the link is computed, not asked for.** Intersect the two notes, keep terms that are rare in
the corpus, and the link is grounded *by construction* rather than by a check that has to catch a
confident wrong answer. The model's job shrinks to writing one sentence about a term it has been
handed — the description task §6.2 established it does well, and it cannot confabulate a link it
did not choose.

Rarity is the discriminator, and it is document frequency for the **third** time in this file —
hub suppression for documents, a ceiling on a proposed term, and now term selection itself.
The ceiling was set by looking at output, not by picking a round number:

| ceiling | what the links looked like |
|---:|---|
| 1,000 | `desktop`×619, `links`×404, `quote`×339, `fresh`×289 — words two work logs share by being work logs |
| **60** | `turbopack`×5, `vital-signs`×6, `initials`×16, `innovative`×19, `aria-label`×20, `webgpu`×23, `postcss`×18 |

60 also cuts `tinacms`×154, which was a genuine link. That is the precision-over-recall trade
Area F asks for, taken knowingly: one false connection destroys trust in all of them; one missed
true connection costs a morning's mild interest.

### 7.5 The pipeline, end to end on the real corpus

```
46,194 neighbour pairs  →  181 candidates  →  35 share a rare term  →  19 described  →  3 in the brief
        0.7 s                Δt≥30d, hub,        grounded by            ~1.5 s each
                             automation          construction
```

The brief's top item, unedited: a **Rezi welcome email from 2025-12-16** connected to
**2026-08-19 work on job-application tooling** by the term `resumes` (43 events), **246 days
apart**, across two sources. That is the "you've been here before" the stage exists for.

One more measured reversal: **`--cross-source-only` is off by default.** Area F's "different
modality" filter assumes several rich modalities; this corpus has one, so requiring a crossing
forced *every* candidate to be gmail↔claudecode — a marketing email paired with real work.
Allowing same-source immediately surfaced two debugging sessions 48 days apart that had hit the
same `aria-label` race. Crossing sources still feeds unexpectedness; it no longer decides
eligibility.

---

## 8. Segmentation and summarization — surprise against a centroid, and citations that are checked

### 8.1 Pairwise distance is not prediction error

Event Segmentation Theory says people cut experience at moments of *prediction error*. The
obvious implementation compares each event to the previous one; the correct one compares it to
a **running centroid of the recent past**, and the difference is not cosmetic:

| stream | max pairwise distance | surprise vs. centroid |
|---|---:|---:|
| A B A B A B (two topics interleaved) | **1.00** | **< 0.60 after the first two** |
| A A A A A A → C C C C C C (a real switch) | 1.00 | **> 0.90 at the switch** |

Interleaving two topics is *maximally surprising* at every single step pairwise, so a pairwise
detector cuts on every event and segments nothing. Against a centroid it correctly reads as one
episode, and a genuine switch still peaks. "Is this different from the last thing?" and "is this
different from what I have been doing?" are different questions, and only the second one is
prediction error.

The threshold is **mean + k·sd of the day's own surprise**, not a constant: a day of one long
build and a day of scattered errands have different surprise scales, and a cutoff calibrated on
one over- or under-segments the other. A gap of 45 minutes cuts regardless of content.

**Not built:** EM-LLM's graph-theoretic refinement, which shifts each boundary to its locally
modularity-maximizing position. What ships is the surprise pass plus temporal contiguity.

### 8.2 Citations are verified, not trusted

Generative Agents cites record IDs, and Area F calls it *"the part most people drop, and it's
what makes the derived layer auditable."* Each summary line carries the `seq` it came from, the
citation column is `NOT NULL`, and a line citing a `seq` outside its own episode is **discarded**
rather than stored — the same groundedness discipline that §7 needed after the model confabulated
its links 38 times out of 40.

On the real corpus (2026-08-20): **26 eligible events → 3 episodes → 21 cited lines, 0 dropped
for citing outside the episode.** Titles came out as "Setting up exo development and
authentication" and "Fixing proxy types and grammar tier issues". Summarization is a description
task, which is the one thing §6.2 and §7.4 both found this model does reliably.

### 8.3 Two things the day boundary got wrong

- **`date(ts,'unixepoch')` is UTC.** An evening event landed in the next day's episode list, so
  the read-out opened with something that happened before yesterday's dinner. A day is the
  person's day: `'localtime'`.
- **A stretch of one event is not an episode.** Short runs now merge into their neighbour;
  without it the day's read-out led with a singleton episode holding one stray notification.

`vectors.i8` also has to be read as `hex(v.i8)` — it is a BLOB, and the text-based row reader
silently loses every byte that is not valid UTF-8.

---

## 9. Decay — the clock was measuring the wrong thing

S6 completes Area F's DAG. `R = exp(ln(0.9)·t/S)`, base stability 60 days, floor 0.30.

**Do the arithmetic rather than reading the constants.** `R < 0.30` needs
`t/S > ln(0.30)/ln(0.9) = 11.4`, so nothing goes cold until it has sat untouched for
**686 days — nearly two years** — and one search resets the clock while raising `S`.

### 9.1 The first pass demoted 2,533 rows and every one of them was wrong

| source | would have gone cold |
|---|---:|
| `iphone.whatsapp` | 951 |
| `iphone.calendar` | 799 |
| `iphone.call` | 686 |
| `iphone.voicemail` / `.note` / `.voicememo` | 97 |
| **anything else** | **0** |

Every single one came from the iPhone backup, and the samples read *"Sydney Holt's Birthday"*,
*"Dale Austin's birthday"*, *"moms birthday"*. Their `ts` is years old; **they had been in this
store for a week.** Nothing had been neglected.

`events.ts` is when a thing *happened*. Decay measures *disuse*, which needs to know when you
**got** it — so the clock is now `ingested_at`, added to the insert path. Rows that predate the
column are backfilled to the migration moment, because the honest statement about a row whose
arrival was never recorded is "the clock starts when we started measuring."

**Consequence: the first decay pass over a backfilled corpus demotes 0, and that is the correct
answer.** 100,106 considered, 0 demoted, 1 immune.

### 9.2 Decay is not retention

| | retention | decay |
|---|---|---|
| basis | **legal** — TTL by class, FRCP 37(e) | **functional** — FSRS on memory strength |
| action | **deletes** | **hides**; row, text, vectors and FTS entry all remain |
| litigation hold | suspends it | irrelevant — nothing is destroyed |
| reversible | no | **yes** — retrieval revives, and strengthens |

A decay pass that deleted would be spoliation dressed as housekeeping; a retention pass that only
hid would be a compliance failure. Six of `decay-test`'s fifteen checks exist purely to hold that
line: the row survives, its text survives, its FTS entry survives so `--include-cold` still finds
it, the default search hides it, retrieval revives it, and `R` never reaches zero at any age.

### 9.3 FSRS needs a signal this system had never recorded

Two years of capture and **not one row saying "you looked at this."** `access` is new here, and
what counts as a retrieval is a judgement call worth naming: *surfaced* in a result list
strengthens weakly (0.6), *opened* strengthens fully (2.0). The Remembrance Agent's finding is the
argument for counting the weak one at all — Rhodes found that seeing the one-line result usually
triggers the memory without opening anything.

Stability grows most when the retrieved memory was nearly forgotten — `S' = S·(1 + w·(1−R))`.
That is the spacing effect, and it is why FSRS beats a fixed half-life: a flat multiplier gives an
already-hot row unbounded stability while a row rescued from the edge gains the same little as
everything else, which is exactly backwards.

**Never decays:** pinned rows, evidence under a *confirmed* belief (demoting it would leave a
belief whose provenance you cannot see), and beliefs in an open contradiction. Area F also names
*commitments until discharged*; that clause is written and currently unreachable, because the
Ledger daemon that produces commitments does not exist yet.

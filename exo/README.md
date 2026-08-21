# exo — Exocortex capture fleet + retrieval + belief ledger + dream cycle

**Phases 1–5.** Multi-source capture → SQLite/FTS5 + binary vector index → hybrid RRF search →
bitemporal belief ledger → contradiction detection → connection discovery, with the retention
policy and capture-exclusion list shipped *now* rather than later.

**Measured results, including one that contradicts the research: [RESULTS.md](RESULTS.md).**

## Build

```bash
bash build/build.sh          # -> build/exo
```

## Use

```bash
./build/exo perms                          # what's granted
./build/exo ingest --days 7                # Claude Code transcripts — zero permissions
./build/exo capture --interval 2           # AX tree + clipboard loop
./build/exo search bitemporal belief --min-trust self
./build/exo retention                      # dry run; --apply to delete
./build/exo hold on --reason "..."         # suspend ALL expiry atomically
./build/exo embed --bits 256                # embed rows lacking a vector
./build/exo search retention --hybrid       # BM25 ∪ vector, fused by RRF k=60
./build/exo bench                           # scan throughput benchmark
./build/exo fs --seconds 30                 # watch the home dir (resumable)
./build/exo bar                             # everything-bar: ⌥Space to toggle
./build/exo stats

./build/exo tell "I hate driving at night"  # record a belief directly
./build/exo ask --n 3                       # short interview; highest confidence tier
./build/exo beliefs me --as-of 2025-06-01T00:00:00Z
./build/exo contradictions --scan           # detect; then review what needs a decision
./build/exo contra-resolve <id> genuine_change
./build/exo connect --histogram             # calibrate the band before trusting it
./build/exo dream                           # the nightly DAG: S4 + S5
./build/exo brief                           # the morning read-out (at most 3)
./build/exo ledger-test                     # 7/7   bitemporal invariants
./build/exo contra-test                     # 15/15 detection + resolution invariants
./build/exo connect-test                    # 13/13 eligibility, grounding, cascade
```

## Backup

`bash tools/backup.sh` — `VACUUM INTO` snapshot into a restic repo, verified restorable
(91,384 events, `integrity_check` ok, FTS working post-restore). **Currently local-only, which
is not yet a real backup** — see [BACKUP.md](BACKUP.md) for the offsite step.

## The everything-bar

`exo bar` puts a non-activating floating panel on **⌃⌥Space** (`--hotkey` to rebind). Phase 0's premise was *run it two
weeks and answer honestly: did you search it?* — and a CLI biases that answer, so the interface is
the feature. It follows the Area I rules drawn from the Remembrance Agent (1996) and the
autocomplete post-mortem: **ignoring is free** (Esc, or click away), it **never steals focus** (your
cursor stays where it was), it doesn't rearrange the screen, and **the one-line result is the
product** — Rhodes found seeing the one-liner usually triggers the memory without opening anything.
Every row carries provenance: `source · trust · app · time`, colour-coded by trust.

## Sources

| Source | Permission | Trust assigned | Notes |
|---|---|---|---|
| **`claudecode`** | **none** | `user`→`self`, `assistant`→`untrusted` | 1,209 files / 1.6 GB, ~53 MB/day. Ingests only `text` blocks — `tool_use`/`tool_result`/`thinking` are most of the bytes and almost none of the meaning |
| **`imessage`** | **Full Disk Access** | mine→`self`, theirs→`third_party` | 380,942 messages, **94.4% carry plain `text`** — the `attributedBody` typedstream problem is a 5.6% tail, counted and skipped rather than half-parsed |
| **`browser.*`** | **Full Disk Access** | `untrusted` (`web`) | Safari + Chrome/Brave/Edge. Opened `?immutable=1` (the browser holds a WAL lock). **Chrome's profile dir is now TCC-protected** — pre-2025 guides are wrong |
| **`fs`** | FDA (outside `~`) | `verified` (`own_file`) | FSEvents with a **persisted `FSEventStreamEventId`**, so a restart replays rather than loses. Records file *events*, never contents |
| **`gmail`** | OAuth (one-time) | mine→`self`, theirs→`third_party` | Restricted scope, **personal-use exempt from CASA**. Refresh token in the Keychain. See **[SETUP-GMAIL.md](SETUP-GMAIL.md)** — the consent screen must be **In production**, or tokens die every 7 days |
| `ax.focus` | Accessibility | `untrusted` (`ocr`) | The AX tree of a webpage is whatever the page says |
| `clipboard` | none | `untrusted` (`ocr`) | Origin unknown by definition |

**Trust is assigned by capture path — never by a model, never by a caller.** The vocabulary matches
[`mcp-bus/CONTRACT.md`](../mcp-bus/CONTRACT.md) §1 exactly, so `min_trust` is enforceable end to end.

## Contradiction detection — four verdicts, and three of them mean nothing is wrong

The queue only ever contains things that need a decision. Everything else closes on detection.

| verdict | what it means | what it does to the ledger |
|---|---|---|
| `genuine_change` | they answer the same question differently, and no situation makes both true | closes the earlier belief where the later one begins |
| `scope_difference` | both true, in different named situations | **nothing** |
| `both_true` | never actually conflicted | **nothing** |
| `extraction_error` | the machine misread one of them | closes that row's *system* record, leaving its belief interval untouched |

**The gate is the belief interval, and only a bitemporal ledger can offer it.** Believing P in
2024 and not-P in 2026 is evolution, not a contradiction — there is nothing to review. A
contradiction is the ledger asserting both *at the same moment*.

Four stages, cheapest first: **overlapping-interval SQL** → **similarity band** (0.55–0.95, Qwen3
int8@256) → **on-device four-way classification** → **`exo contra-resolve`**. Stages 1–3 fill a
queue; only a person changes the ledger.

Two things the measurements decided, both in [RESULTS.md §6](RESULTS.md):

- **`NLEmbedding` cannot filter belief pairs at any threshold** — it puts real contradictions
  *inside* the unrelated range. The retrieval stack's Qwen3 int8 tier separates with a 0.135
  margin, and separates *better than full float*, while the binary tier at the same width is
  unusable (0.007). Same vectors, opposite verdict from §2's retrieval eval.
- **The model will not call anything a contradiction, but it will describe one accurately.**
  Asked to judge, it returned `scope_difference` for 14 of 14 pairs including a head-on
  contradiction. Asked in a *separate call* what question each statement answers, it writes the
  identical question twice — so the judgement is made in code instead. **P = 1.0, R = 0.5** on a
  small labelled set, which is the shape Area E asks for: *"false positives destroy it."*

## Connection discovery — what similarity actually finds

`exo dream` runs the nightly stages that exist; `exo brief` is the read-out, capped at **three**
because *one false connection destroys trust in all of them*.

```
46,194 neighbour pairs  →  181 candidates  →  35 share a rare term  →  19 described  →  3 in the brief
        0.7 s                Δt≥30d, hub,        grounded by
                             automation          construction
```

**The first twelve findings were twelve pieces of infrastructure** — a Claude.ai sign-in email
matched to the Claude.ai sign-in URL at 0.911, four marketing emails matched to
`Base directory for this skill: /private/tmp/…`. None of Area F's filters touch that, because
the candidates were not wrong: a login email and a login URL really are different sources, really
142 days apart, really about one thing. **Similarity search over a life-log finds the corpus's
hubs, and a life-log's hubs are its boilerplate.**

So **88% of the vectorized corpus is ineligible** to be one end of a connection — `browser.*` is
99.6% bare URLs, a third of the whole index. And **the link is computed rather than asked for**:
the model confabulated it 38 times out of 40, naming something that occurs in one note and not
the other, and a schema-level escape hatch went unused 39 times out of 39. Intersecting the two
notes and keeping rare terms makes the link grounded *by construction*. Full numbers in
[RESULTS.md §7](RESULTS.md).

## Retention — the FRCP 37(e) defense

| Class | TTL | Why |
|---|---|---|
| `text` | forever | ~6 GB/decade, cheaper than the vectors it generates |
| `raw_frame` | 21 days | 228 GB budget makes the pixel tier a cache, not an archive |
| `sensitive` | 30 days | T3: health, finance, legal |
| `correspondence` | 5 years | Messages **other people** sent me — their data, deliberately shorter than my own, but long enough to be useful. Messages.app remains the system of record |
| `third_party` | 14 days | Shortest of all (*Ryneš* C-212/13) |

The policy is written with an **effective date at store creation**, expiry runs on a schedule, every
purge writes a **receipt**, and `hold on` suspends all classes atomically. Rule 37(e) permits
adverse-inference sanctions only on *"intent to deprive"*, and the committee note says reasonable steps
*"does not call for perfection"* — so routine documented operation predating any dispute is the
defense. **The same deletion after a duty to preserve attaches is spoliation.** That is why this ships
in Phase 1 and not Phase 6.

## Verified on M5 / macOS 27, 2026-08-19

**7/7 regression tests pass.** Real numbers from this machine:

- **885 events ingested from real transcripts in 1.2 s**; 10,389 records skipped by the noise filter;
  **72 secret-shaped lines redacted**
- Ingest is **idempotent** — re-running ingests nothing (per-file resume cursor)
- **Expiry actually deletes**: a backdated `third_party` row was purged at ttl=14d, a receipt written,
  and the **external-content FTS5 index stayed in sync at 885/885** (it silently drifts on delete
  unless the index is explicitly told — hence the `events_ad` trigger)
- Litigation hold suspends all three TTL classes and overrides `--apply`
- Exclusion: `ConcealedType` clipboard items are **never stored**, secret-shaped content is dropped,
  ordinary text is captured, and re-runs don't duplicate it

## Known limits

- **Unbundled executables are never captured.** A bare SwiftPM binary has no `bundleIdentifier`, so
  `Exclusion.check` fails closed with `unidentified-app`. Correct by design; the ledger records the app
  name so it's diagnosable.
- Private-browsing detection is **title-regex only** — spoofable and localized. The durable fix is a
  browser extension signalling over a local socket (Phase 2).
- Single `events.db`. The **split encrypted `content.db`** (SQLite3MultipleCiphers, ChaCha20-Poly1305,
  holding payloads + the FTS index) is Phase 2 — an FTS5 index over your text is a searchable
  concordance of your life and belongs on the encrypted side.
- **Contradiction recall is about half.** The identity test catches a change of mind only when the
  model frames both statements as the same question; reframed pairs ("I don't drink anymore" /
  "I enjoy a glass of wine most evenings") score 0.556 and are missed. Closing that gap is what
  Area E's DeBERTa NLI stage was for, and there is no NLI model on this machine.
- **Timestamps are ISO8601 to the second.** Two beliefs recorded in the same second — every answer
  in one `exo ask` sitting — tie, and `genuine_change` correctly refuses them: you cannot have
  changed your mind between two things you wrote down simultaneously. The command says so and
  names the verdicts that do apply.
- **`availability` is not a guarantee.** The text sanitizer screening every on-device request can
  fail system-wide (`SensitiveContentAnalysisML 15` → `ModelManagerError 1013`) while
  `SystemLanguageModel.default.availability` still answers `.available`. `scan` and `extract` both
  abort after 3 consecutive failures and say the run is **not** a clean bill of health. It cleared
  on its own here; a restart reloads the sanitizer.

## Next

S4, S5 and S8 of Area F's DAG are built and `exo dream` runs them. Still missing: **S1**
segmentation by prediction error, **S2** hierarchical map-reduce summarization, and **S6** FSRS
decay (`R = exp(ln(0.9)·t/S)`, demote to cold storage, never hard-delete). Then the daemons —
Scout, Butler, Ledger, Historian, Editor.

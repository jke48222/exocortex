# exo — Exocortex capture fleet + retrieval

**Phases 1–2.** Multi-source capture → SQLite/FTS5 + binary vector index → hybrid RRF search,
with the retention policy and capture-exclusion list shipped *now* rather than later.

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
./build/exo stats
```

## Sources

| Source | Permission | Trust assigned | Notes |
|---|---|---|---|
| **`claudecode`** | **none** | `user`→`self`, `assistant`→`untrusted` | 1,209 files / 1.6 GB, ~53 MB/day. Ingests only `text` blocks — `tool_use`/`tool_result`/`thinking` are most of the bytes and almost none of the meaning |
| **`imessage`** | **Full Disk Access** | mine→`self`, theirs→`third_party` | 380,942 messages, **94.4% carry plain `text`** — the `attributedBody` typedstream problem is a 5.6% tail, counted and skipped rather than half-parsed |
| **`browser.*`** | **Full Disk Access** | `untrusted` (`web`) | Safari + Chrome/Brave/Edge. Opened `?immutable=1` (the browser holds a WAL lock). **Chrome's profile dir is now TCC-protected** — pre-2025 guides are wrong |
| `ax.focus` | Accessibility | `untrusted` (`ocr`) | The AX tree of a webpage is whatever the page says |
| `clipboard` | none | `untrusted` (`ocr`) | Origin unknown by definition |

**Trust is assigned by capture path — never by a model, never by a caller.** The vocabulary matches
[`mcp-bus/CONTRACT.md`](../mcp-bus/CONTRACT.md) §1 exactly, so `min_trust` is enforceable end to end.

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

## Next (Phase 1 remainder)

Browser history, iMessage (`imessage-exporter` as a **subprocess** — it's GPL-3.0 and cannot be linked
into a notarized proprietary app), Gmail (**consent screen set to Production-unverified**, because
Testing status expires refresh tokens every 7 days), and FSEvents with a persisted stream ID.

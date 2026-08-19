# Exocortex MCP Memory Bus — Contract v1.0.0 (FROZEN)

**Status:** FROZEN 2026-08-19. **Do not change a field without a major-version bump and a 6-month deprecation window.**
**Wire spec baseline:** MCP revision `2026-07-28` (stateless; sessions removed; Sampling/Roots/Logging deprecated).
**Transport for the local bus:** `stdio`. (Remote is out of scope for v1; if ever added it is a new major.)

This document is the build target for **Oracle Phone (P15)**, **Pocket Star (P20)**, and **Desk Creature (P21)**.
Those three builds involve hand-assembled hardware (36 split-flap modules in P15) and cannot cheaply re-spec against a moving API.
The contract is therefore frozen *before* any of them start.

---

## 0. Why this shape

- **No mass-read primitive.** The reference MCP `memory` server ships `read_graph()` with no args — a single-call full-life dump, i.e. the exact shape of a mass-exfiltration tool. mem0's OpenMemory ships `list_memories` + `delete_all_memories`. **Neither is replicated here.**
- **`source_kind` is required on writes but is an enum of CHANNELS, not a trust level.** The server maps channel -> trust. A caller can never assert its own trust. This defeats the delayed-tool-invocation attack (an injected instruction that makes a model claim its write is user-authored).
- **`memory.context` is the answer to "the bus wants to push but can't."** MCP `sampling` is deprecated and unsupported on the likely hosts, so the bus cannot borrow a client's model. One bounded, pre-sanitized, purpose-scoped, budget-capped call at session start replaces a dozen unbounded recalls. It is the single call the hardware clients actually make.
- **Every result is `cacheScope: "private"`.** A `"public"` scope on a life-memory read is a breach via any shared intermediary.
- **Per-client scoping derives from the per-request credential**, which is the only per-request variation the 2026-07-28 spec permits on `tools/list`. Different clients present different credentials, never different connections.

---

## 1. Trust tiers

Trust is assigned **at capture, by the ingest path**, never by a model and never by a tool argument.
Derived memories inherit `min(trust)` of their sources. Nothing below `verified` is ever returned as bare prose —
only inside a labeled `structuredContent` envelope. **Trust elevation requires an out-of-band human action; there is no tool for it.**

| Level        | Source                                                             | Retrievable by default | May influence a tool call |
|--------------|-------------------------------------------------------------------|------------------------|---------------------------|
| `self`       | typed/spoken by the principal on a trusted input path             | yes                    | yes                       |
| `verified`   | first-party systems the principal controls (own calendar, notes)  | yes                    | yes                       |
| `third_party`| authenticated known correspondent (a real contact's email)        | on request             | **no**                    |
| `untrusted`  | web, OCR of arbitrary screen content, unknown senders, others' speech | only with explicit `min_trust:"untrusted"` | **never** |

---

## 2. The nine tools

All namespaced `memory.*`, returned in this fixed order (for prompt-cache hit rates), `openWorldHint:false` on all.
Annotations are **documentation, not enforcement** — the 2026-07-28 schema says clients must treat annotations from
untrusted servers as untrusted. The real controls are the tiered architecture and the local approval UI, not `readOnlyHint`.

| # | Tool | Params | Returns (structuredContent) | readOnly | destructive | idempotent | Tier |
|---|------|--------|------------------------------|:--------:|:-----------:|:----------:|:----:|
| 1 | `memory.recall` | `query:string`, `k:int<=50 =8`, `since?:date-time`, `until?:date-time`, `kinds?:enum[]`, `min_trust:enum =verified`, `purpose:enum` | `{items[], truncated:bool, budget_remaining:int}` | ✔ | ✗ | ✔ | 1 |
| 2 | `memory.timeline` | `start:date-time`, `end:date-time`, `granularity:day\|week\|month`, `kinds?`, `min_trust =verified` | `{buckets:[{period,items[],count}]}` | ✔ | ✗ | ✔ | 1 |
| 3 | `memory.beliefs_at` | `subject:string`, `as_of:date-time`, `include_superseded:bool =false` | `{beliefs:[{text,valid_from,valid_to,belief_from,belief_to,learned_at,superseded_by?,trust,confidence,confidence_src}]}` | ✔ | ✗ | ✔ | 1 |
| 4 | `memory.commitments` | `status:open\|done\|overdue\|all =open`, `with_person?`, `due_before?`, `due_after?` | `{commitments:[{id,text,counterparty,due,status,origin_episode_id,trust}]}` | ✔ | ✗ | ✔ | 2 |
| 5 | `memory.context` | `purpose:enum` (server allowlist), `token_budget:int<=8000 =2000`, `focus?:string` | `{brief:string, items[], as_of, budget_used:int, redactions:int}` | ✔ | ✗ | ✗ (time-varying) | 1 |
| 6 | `memory.remember` | `text:string`, `kind:enum`, `occurred_at?`, `subjects?:string[]`, **`source_kind:enum` (REQUIRED)**, `confidence?:number` | `{id, status:"pending_approval"\|"stored", trust_assigned, receipt}` | ✗ | **false** | ✗ | 3 |
| 7 | `memory.correct` | `id:string`, `new_text:string`, `reason:string` | `{new_id, superseded_id, valid_to}` | ✗ | **false** (bitemporal supersede, not erase) | ✗ | 3 |
| 8 | `memory.forget` | `id?` XOR `query?`, `confirm_token:string` (issued by the LOCAL approval UI) | `{tombstoned:int}` | ✗ | **true** | ✔ | 4 |
| 9 | `memory.provenance` | `id:string` | `{episode_id, source_kind, captured_at, capture_path, trust, derived_from[], derived_to[]}` | ✔ | ✗ | ✔ | 4 |

`recall` item shape: `{id, text, kind, occurred_at, recorded_at, trust, confidence, source_kind, episode_id}`.

### Enums (frozen)
- `kind`: `event` | `fact` | `belief` | `commitment` | `person` | `place` | `artifact`
- `source_kind` (channels; server maps channel -> trust): `typed` | `voice_self` | `own_note` | `own_calendar` | `own_file` | `screen_coach` | `email_known` | `email_unknown` | `web` | `ocr` | `transcript_other`
- `purpose` (per-client scope): `oracle` | `companion` | `coding` | `writing` | `personal` | `briefing`
- `min_trust`: `self` | `verified` | `third_party` | `untrusted`

---

## 3. Per-client allowlists (what the hardware builds may call)

Enforced by the credential each client presents. A client calling a tool outside its allowlist gets `error.forbidden`.

| Client | Credential `purpose` | Allowed tools | Notes |
|--------|----------------------|---------------|-------|
| **Oracle Phone (P15)** | `oracle` | `recall` (k<=5), `context` | Output is **36 characters**. Server returns a `oneline` field per item (<=36 chars); the phone never sees full text. **No writes** — a rotary phone cannot express consent. |
| **Pocket Star (P20)** | `companion` | `context` (token_budget<=512) | Battery-bound: one call per wake, cached locally, never streams. |
| **Desk Creature (P21)** | `companion` | `context`, `recall`, `commitments`; `remember` **only via the local approval UI** | Holds its own human-readable `~/creature/memory.md` projection, regenerated nightly from `context`. The creature never writes to the vault directly; deleting its file deletes what it knows, not your life. |
| Coding agent | `coding` | `recall`, `context`, `beliefs_at` | Narrow projection; no `commitments`; small budget. |
| Writing agent (Editor) | `writing` | `recall`, `context`, `beliefs_at`, `commitments` | Larger budget. |

**Open-world clients (a client that also has web/shell/email) get the NARROW projection only:** non-PII, `self`/`verified`
trust, tiny budget, no writes, heavily canaried. If you would not be comfortable seeing a memory published, it must never
enter the projection served to an agent that has web access.

---

## 4. Error model

`tools/call` returns a normal result with `isError:true` and `structuredContent.error = {code, message}`. Codes (frozen):
`forbidden` (tool not in this client's allowlist) · `budget_exceeded` (per-client rolling token cap hit) ·
`needs_approval` (a Tier-3 write is queued in the local UI; retry after approval) · `not_found` ·
`invalid_argument` · `rate_limited`. **The audit log is never exposed as a tool** — that would hand an attacker the
canary registry.

## 5. Versioning

Every response carries `_meta."exocortex.contract_version" = "1.0.0"`. The bus refuses a client declaring an
incompatible **major**. Additive fields bump **minor**. Removing or narrowing a field bumps **major** and requires a
**6-month deprecation window**. Same discipline the MCP spec now applies to itself.

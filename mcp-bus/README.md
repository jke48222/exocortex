# mcp-bus — the memory contract, and a server that honours it

**`CONTRACT.md`** is the frozen v1.0.0 spec. **`schema/tools.json`** is the machine-checkable
tool surface. **`store.py`** is the read-only data + egress layer. **`server.py`** is a stdio
MCP server now backed by the **real store** (91,384 events at time of writing).

```bash
# what this client is allowed to see
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | EXO_PURPOSE=oracle python3 server.py | jq '[.result.tools[].name]'

# a real recall
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory.recall","arguments":{"query":"orrery accuracy","purpose":"personal","k":3}}}' \
  | EXO_PURPOSE=personal python3 server.py | jq '.result.structuredContent.items'
```

Env: `EXO_PURPOSE` (client credential), `EXO_DB`, `EXO_AUDIT`, `EXO_CANARIES` (`|`-separated).

## Wiring it into Claude Code

```json
{ "mcpServers": {
    "exocortex": {
      "command": "python3",
      "args": ["/Users/jalenedusei/fun-project/exocortex/mcp-bus/server.py"],
      "env": { "EXO_PURPOSE": "coding" }
    } } }
```

Use `EXO_PURPOSE=coding` for any client that also has web or shell access — it is treated as
**open-world** and gets the narrow projection only.

## Verified against the real store, 8/8

| Invariant | Result |
|---|---|
| Real recall over 91,384 events | ✅ returns ranked, sanitized items |
| `min_trust` filters | ✅ `self` returns only `self`; `untrusted` widens |
| **Open-world clients cannot reach `third_party`/`untrusted`** | ✅ 0 leaked |
| Per-purpose `k` cap (oracle ≤5) | ✅ asked for 40, got 5 |
| Oracle Phone `oneline` ≤36 chars, readable prose | ✅ 36/36 |
| Allowlist: oracle → `commitments` | ✅ `forbidden` |
| `forget` without a local `confirm_token` | ✅ `needs_approval` |
| No mass-read tool exists | ✅ 0 |
| Every result `cacheScope: private` | ✅ |
| **Egress sanitisation on real data** | ✅ **0 raw URLs leaked** |
| **Canary rows stripped and reported** | ✅ |
| Audit hash chain | ✅ 12 entries, intact |
| Audit exposed as a tool | ✅ **no** — deliberately |

## What it deliberately does not do

**`beliefs_at` and `commitments` return empty with an `_unavailable` note.** They are backed
by the bitemporal belief ledger, which is Phase 3 and does not exist yet. Returning an empty
list and saying so beats inventing plausible beliefs — **a memory system that fabricates is
worse than one that admits a gap**, and this is exactly the failure mode PASS-4 Area A found
in the benchmark literature.

**`remember` / `correct` / `forget` do not write.** Writes belong to Tier 1 (the quarantined
curator) behind a local approval UI, neither of which is built. They return `needs_approval`.

**This process has no write path and no network.** That is the point: Tier 1 sees untrusted
content but cannot recall or egress; Tier 2 (this) can recall but cannot write or egress.
Neither tier alone completes the lethal trifecta. The guarantee is architectural, not a
promise in a docstring.

## Egress controls

Every returned string passes `store.sanitize()`, which strips markdown images, inline **and
reference-style** links (EchoLeak/CVE-2025-32711 used reference-style specifically to dodge
redaction), autolinks, bare URLs, `data:` URIs, HTML, and the Unicode tag block plus
zero-width/bidi characters used for ASCII smuggling. Measured on real data: **0 raw URLs in
output.**

Canaries are seeded via `EXO_CANARIES` so the registry never lives in the repo. A canary that
appears in output is stripped and counted; a canary that appears **anywhere else** means the
database was read directly rather than through the bus.

# exocortex

**Project 22 of the portfolio — the spine.** A local-first virtual brain: append-only encrypted life
log, episodic/semantic/procedural memory, cognition daemons, and an MCP memory bus that gives every AI
tool one shared persistent memory.

Research: [`portfolio-research/PASS-4-exocortex-crossportfolio-research.md`](../portfolio-research/).

## What's here

| Component | Status | Headline |
|---|---|---|
| **[`exo/`](exo/)** — Phases 1–7: capture → vectors → belief ledger → contradictions → connections → episodes → decay | ✅ built, **60/60 tests** | 14 sources, 100k events, 0.95 Recall@1 hybrid retrieval, bitemporal belief ledger, four-way contradiction detection, **Area F's nightly DAG complete** (S1/S2/S4/S5/S6/S8) + morning brief |
| **[`mcp-bus/`](mcp-bus/)** — the memory contract | ✅ **v1.0.0 FROZEN** | 9 tools, 4 trust tiers; invariants proven by smoke tests |

## exo — Phase 1

Its entire job is to answer one question after two weeks of real use: **did you search it?**
Every dead life-log in the landscape died on that answer; finding out costs 20 hours, not 2,000.

```bash
bash exo/build/build.sh          # -> exo/build/exo
./exo/build/exo perms            # is Accessibility granted?
./exo/build/exo capture          # AX-tree capture loop
./exo/build/exo search arcminute precision
./exo/build/exo seed             # synthetic events; proves store+search with no TCC grant
```

Proven on M5 / macOS 27: external-content **FTS5 + BM25** with index integrity 5==5 · live `ax.focus`
capture · content-hash **dedup** skips unchanged states · **capture exclusion** records
`source='exclusion.suppressed'` with **text length 0** — it logs *that* it suppressed, never *what*.

## mcp-bus — contract v1.0.0, frozen

Blocking dependency for **Oracle Phone**, **Pocket Star** and **Desk Creature**. Frozen before any of
them start, because 36 hand-assembled split-flap modules can't be re-spec'd.

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | EXO_PURPOSE=oracle python3 mcp-bus/server.py | jq '[.result.tools[].name]'
```

Proven invariants: a `web`-channel write claiming `trust:self` is **server-reassigned to `untrusted`** ·
the Oracle Phone credential is **forbidden** from `commitments` · `forget` needs a local-UI
`confirm_token` · `recall.k` hard-capped at 50 · every result `cacheScope:"private"` ·
**no mass-read primitive.**

## Sibling repos

The two spikes that informed this design now live in their own repos, since both are separate portfolio
projects: **[`livetype`](../livetype/)** (font-cache invalidation — **negative result**, and the reason
the everything-bar stays the primary read-out) and **[`chronofield`](../chronofield/)** (ICS writeback —
harness built, cross-client run pending).

## Next

**Phase 8 — the daemons.** Area F's nightly DAG is complete: S1 segment, S2 summarize, S4
contradict, S5 connect, S6 decay, S8 brief, all run by `exo dream`. What remains are the five
daemons — **Scout** (nightly, question rot at 60d), **Butler** (calendar T−30, cap at 5 bullets,
lead with unresolved commitments), **Ledger** (real-time, tune to P≈0.9 even at R=0.5),
**Historian** (Sunday, *"some weeks have no story; say so"*), **Editor** (on request only, never
autonomous) — plus EM-LLM's graph-theoretic refinement of S1's boundaries.

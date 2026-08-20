#!/usr/bin/env python3
"""
Exocortex MCP Memory Bus — reference stub server (contract v1.0.0).

Contract reference, NOT a production server. It exists so Oracle Phone (P15),
Pocket Star (P20) and Desk Creature (P21) can build against a live, frozen
tool surface today. It serves the frozen schemas from schema/tools.json and
enforces the two invariants that are actually load-bearing:

  1. Per-client allowlist  — a client's `purpose` credential (env EXO_PURPOSE)
     gates which tools it may list/call. Out-of-allowlist -> error.forbidden.
  2. Server-assigned trust — memory.remember assigns trust from `source_kind`
     (a channel). Any client-supplied trust is ignored. This defeats the
     delayed-tool-invocation / self-elevation attack.

Transport: stdio, newline-delimited JSON-RPC 2.0 (MCP 2026-07-28 is stateless;
no initialize handshake required). Methods: server/discover, tools/list, tools/call.
Backed by the real store as of contract v1.0.0. Read-only by construction: this process
has no write path and no network, so Tier 1 (curator) and Tier 2 (this) each hold only one
leg of the lethal trifecta.
"""
import sys, json, os, uuid, datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store as ST

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = json.load(open(os.path.join(HERE, "schema", "tools.json")))
TOOLS = {t["name"]: t for t in DOC["tools"]}
CONTRACT = DOC["contract_version"]

# server-side channel -> trust map. The client never gets to assert trust.
CHANNEL_TRUST = {
    "typed": "self", "voice_self": "self",
    "own_note": "verified", "own_calendar": "verified", "own_file": "verified",
    "screen_coach": "verified",
    "email_known": "third_party",
    "email_unknown": "untrusted", "web": "untrusted", "ocr": "untrusted",
    "transcript_other": "untrusted",
}

def purpose():
    return os.environ.get("EXO_PURPOSE", "personal")

# Clients that also hold web/shell/email access. Area L's verdict: never serve these the
# bus, only a narrow projection, under a standing assumption the projection is public.
OPEN_WORLD = {"coding", "briefing"}
# Per-purpose k caps from CONTRACT.md §3. Oracle Phone drives a 36-character split-flap
# board, so more than a handful of results is meaningless there.
PURPOSE_KMAX = {"oracle": 5, "companion": 12}
PURPOSE_BUDGET = {"oracle": 4000, "companion": 8000, "coding": 20000,
                  "writing": 60000, "personal": 100000, "briefing": 20000}
PURPOSE_SEED = {"oracle": "", "companion": "", "coding": "", "writing": "",
                "personal": "", "briefing": ""}
BUDGETS = {}

# Class-B retrieval canaries: uniquely-worded strings that should never legitimately
# match. If one is ever returned, the tuple (trust x purpose) tells you which projection
# leaked. Seeded via EXO_CANARIES so the registry is not in the repo.
CANARIES = [c for c in os.environ.get("EXO_CANARIES", "").split("|") if c]

def strip_canaries(items):
    """Remove canary rows from output and report the hit. Storage canaries must never be
    served; their appearance anywhere means the DB itself was read directly."""
    if not CANARIES:
        return items, 0
    keep, hits = [], 0
    for i in items:
        if any(c.lower() in i.get("text", "").lower() for c in CANARIES):
            hits += 1
            continue
        keep.append(i)
    return keep, hits

def allowed(tool_name, p):
    t = TOOLS.get(tool_name)
    return bool(t) and p in t["_meta"]["exocortex.client_allowlist"]

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def ok(id_, result):
    result.setdefault("_meta", {})["exocortex.contract_version"] = CONTRACT
    return {"jsonrpc": "2.0", "id": id_, "result": result}

def rpc_err(id_, code, msg):
    return {"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": msg}}

def tool_error(id_, code, msg):
    # MCP surfaces tool-level failures as a normal result with isError=true
    return ok(id_, {"isError": True,
                    "structuredContent": {"error": {"code": code, "message": msg}},
                    "content": [{"type": "text", "text": f"[{code}] {msg}"}]})

def tool_ok(id_, structured):
    return ok(id_, {"isError": False, "structuredContent": structured,
                    "content": [{"type": "text", "text": json.dumps(structured)}],
                    "cacheScope": "private", "ttlMs": 0})

def handle_call(id_, params):
    p = purpose()
    name = params.get("name")
    args = params.get("arguments", {}) or {}
    if name not in TOOLS:
        return tool_error(id_, "not_found", f"unknown tool {name!r}")
    if not allowed(name, p):
        return tool_error(id_, "forbidden",
                          f"client purpose={p!r} may not call {name!r}")

    if name == "memory.remember":
        sk = args.get("source_kind")
        if sk not in CHANNEL_TRUST:
            return tool_error(id_, "invalid_argument", "source_kind required (a channel enum)")
        trust = CHANNEL_TRUST[sk]                      # SERVER assigns, client cannot
        tier3_needs_approval = True
        return tool_ok(id_, {"id": "mem_" + uuid.uuid4().hex[:8],
                             "status": "pending_approval" if tier3_needs_approval else "stored",
                             "trust_assigned": trust,
                             "receipt": "queued to local approval UI",
                             "_note": "trust assigned from source_kind by the server; any client-supplied trust ignored"})

    if name == "memory.forget":
        if not args.get("confirm_token"):
            return tool_error(id_, "needs_approval",
                              "memory.forget requires a confirm_token issued by the local approval UI")
        return tool_ok(id_, {"tombstoned": 0, "_note": "stub: no store attached"})

    # per-client rolling budget: exfiltration looks like a mass read
    budget = BUDGETS.setdefault(p, PURPOSE_BUDGET.get(p, 40000))

    if name == "memory.recall":
        k = min(int(args.get("k", 8)), 50)
        mt = args.get("min_trust", "verified")
        # An open-world client (one that also has web/shell access) gets the NARROW
        # projection regardless of what it asks for. Area L: everything reachable by such
        # a client must be treated as already public.
        if p in OPEN_WORLD:
            mt = "verified" if mt in ("third_party", "untrusted") else mt
        k = min(k, PURPOSE_KMAX.get(p, 50))
        items = ST.recall(args.get("query", ""), k=k, since=args.get("since"),
                          until=args.get("until"), kinds=args.get("kinds"), min_trust=mt)
        items, hits = strip_canaries(items)
        spent = sum(len(i["text"]) for i in items) // 4
        BUDGETS[p] = max(0, budget - spent)
        red = sum(i.pop("redactions", 0) for i in items)
        ST.audit(p, name, args, len(items), red)
        if BUDGETS[p] <= 0:
            return tool_error(id_, "budget_exceeded", "per-client rolling token budget spent")
        return tool_ok(id_, {"items": items, "truncated": len(items) >= k,
                             "budget_remaining": BUDGETS[p], "canary_hits": hits})

    if name == "memory.timeline":
        b = ST.timeline(args.get("start", 0), args.get("end", 9e18),
                        args.get("granularity", "day"),
                        args.get("min_trust", "verified"))
        ST.audit(p, name, args, len(b), 0)
        return tool_ok(id_, {"buckets": b})

    if name == "memory.context":
        tb = min(int(args.get("token_budget", 2000)), 8000)
        focus = args.get("focus") or PURPOSE_SEED.get(p, "")
        mt = "verified" if p in OPEN_WORLD else "third_party"
        items = ST.recall(focus, k=8, min_trust=mt, limit_chars=240) if focus else []
        items, hits = strip_canaries(items)
        used, keep = 0, []
        for i in items:
            c = len(i["text"]) // 4
            if used + c > tb: break
            used += c; keep.append(i)
        red = sum(i.pop("redactions", 0) for i in keep)
        st = ST.stats()
        brief = (f"{st['events']:,} events, {st['span'][0][:10]}..{st['span'][1][:10]}. "
                 f"{len(keep)} items for purpose={p}.")
        ST.audit(p, name, args, len(keep), red)
        return tool_ok(id_, {"brief": brief, "items": keep, "as_of": now(),
                             "budget_used": used, "redactions": red, "canary_hits": hits})

    if name == "memory.provenance":
        r = ST.provenance(args.get("id", ""))
        ST.audit(p, name, args, 1 if r else 0, 0)
        if not r:
            return tool_error(id_, "not_found", f"no such id {args.get('id')!r}")
        return tool_ok(id_, r)

    # Backed by the bitemporal belief ledger, which is Phase 3 and does not exist yet.
    # Returning an empty list with an explicit note beats inventing plausible beliefs —
    # a memory system that fabricates is worse than one that admits a gap.
    if name in ("memory.beliefs_at", "memory.commitments"):
        key = "beliefs" if name.endswith("beliefs_at") else "commitments"
        ST.audit(p, name, args, 0, 0)
        return tool_ok(id_, {key: [], "_unavailable":
                             "the bitemporal belief ledger is not built yet (Phase 3); "
                             "this returns empty rather than fabricating"})

    if name == "memory.correct":
        return tool_error(id_, "needs_approval",
                          "writes are queued in the local approval UI, which is not built yet")

    return tool_error(id_, "not_found", f"unhandled tool {name!r}")

def handle(req):
    id_ = req.get("id")
    m = req.get("method")
    params = req.get("params", {}) or {}
    p = purpose()
    if m == "server/discover":
        return ok(id_, {"serverInfo": {"name": "exocortex-memory-bus", "version": CONTRACT},
                        "capabilities": {"tools": {"listChanged": False}},
                        "instructions": "Frozen contract v1.0.0. Read-mostly. Writes gated by local UI."})
    if m == "tools/list":
        visible = [t for t in DOC["tools"] if p in t["_meta"]["exocortex.client_allowlist"]]
        return ok(id_, {"tools": visible})
    if m == "tools/call":
        return handle_call(id_, params)
    if m and m.startswith("notifications/"):
        return None
    return rpc_err(id_, -32601, f"method not found: {m}")

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()

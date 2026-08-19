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
"""
import sys, json, os, uuid, datetime

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

    if name == "memory.context":
        tb = min(int(args.get("token_budget", 2000)), 8000)
        return tool_ok(id_, {"brief": "(stub) purpose-scoped brief would appear here",
                             "items": [], "as_of": now(), "budget_used": 0,
                             "redactions": 0, "_budget_cap": tb})

    if name == "memory.recall":
        k = min(int(args.get("k", 8)), 50)
        return tool_ok(id_, {"items": [], "truncated": False, "budget_remaining": 40000,
                             "_k_cap": k})

    # remaining read tools: schema-valid empty stubs
    empties = {
        "memory.timeline": {"buckets": []},
        "memory.beliefs_at": {"beliefs": []},
        "memory.commitments": {"commitments": []},
        "memory.correct": {"new_id": "", "superseded_id": ""},
        "memory.provenance": {"episode_id": "", "trust": "self"},
    }
    return tool_ok(id_, empties.get(name, {}))

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

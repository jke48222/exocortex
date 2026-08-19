# mcp-bus — the frozen memory contract

**`CONTRACT.md`** is the human spec (frozen v1.0.0). **`schema/tools.json`** is the machine-checkable tool
surface (MCP `tools/list` payload, JSON Schema 2020-12). **`server.py`** is a stdlib-only stdio reference
stub so the three hardware clients can build against a live target today.

```bash
# list the tools this client is allowed to see
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | EXO_PURPOSE=oracle python3 server.py | jq '[.result.tools[].name]'
```

Reference, not production. Handlers return schema-valid stubs; the two load-bearing invariants
(per-client allowlist, server-assigned trust) are enforced for real.

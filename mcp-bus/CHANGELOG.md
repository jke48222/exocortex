# Changelog — Exocortex MCP Memory Bus

## 1.0.0 — 2026-08-19 — FROZEN
- Initial frozen contract. 9 `memory.*` tools, 4 trust tiers, per-client allowlists.
- Blocking dependency for Oracle Phone (P15), Pocket Star (P20), Desk Creature (P21) — frozen before any start.
- Invariants proven by `server.py` smoke tests: per-client scoping; server-assigned trust from `source_kind`
  (client cannot self-elevate); no mass-read primitive; `forget` gated on a local-UI `confirm_token`;
  `recall.k` hard-capped at 50; every result `cacheScope:"private"` and version-stamped.
- Deprecation policy: additive -> minor; remove/narrow a field -> major + 6-month window.

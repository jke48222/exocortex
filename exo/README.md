# exo — Exocortex Phase 0

Capture → SQLite/FTS5 → one search box. The weekend spike from the Pass-4 roadmap.
Its entire job is to answer one question after two weeks of use: **did you search it?**
Every dead life-log in the landscape died on that answer; finding out costs 20 hours, not 2,000.

## Build
```bash
bash build/build.sh          # -> build/exo  (Swift 6.3, swift-version 5, AppKit+ApplicationServices+libsqlite3)
```

## Use
```bash
./build/exo perms                    # is Accessibility granted?
./build/exo capture --interval 2     # AX-tree capture loop (Ctrl-C to stop)
./build/exo search arcminute precision
./build/exo stats
./build/exo seed                     # synthetic events, proves store+search with no TCC grant
```

## What's proven here (ran clean on M5 / macOS 27, 2026-08-19)
- **Store + search**: external-content **FTS5 + BM25**, `snippet()` match highlighting, index integrity 5==5.
- **Live AX capture**: `capture --once` reads the frontmost app via `AXUIElementCopyAttributeValue`
  (`ax.focus` source) and writes a real row.
- **Dedup**: an identical consecutive state is skipped (content-hash).
- **Capture exclusion (Area L)**: password-manager bundle ids are suppressed — the row records
  `source='exclusion.suppressed'` with **text length 0**. It logs THAT it suppressed, never WHAT.

## What needs YOUR one-time action
- **Accessibility grant** for richer text from other apps' focused fields: System Settings →
  Privacy & Security → Accessibility → add the process running `exo`. (Already granted on this machine.)
- Phase-1 additions (not in this spike): OCR fallback via Vision `.fast`, `IsSecureEventInputEnabled()`
  suppression, the split `content.db` encryption, and the browser/iMessage/Gmail/Claude-Code-JSONL sources.

## Faithful to the dossier
Area B (AX-tree primary, OCR fallback) · Area C (STRICT schema, `page_size=8192`, WAL, `synchronous=NORMAL`,
content-hash dedup) · Area D (external-content FTS5, BM25) · Area L (capture-exclusion list at the source).

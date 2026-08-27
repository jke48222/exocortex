# Exocortex

Every AI assistant forgets you the moment you close the window. Exocortex is a personal memory
that does not: it captures your own life log (messages, mail, browsing, files, terminal
transcripts, phone backups) into one encrypted store on your own machine, and lends that memory
out to any AI tool through a permissioned local server, so they share one memory instead of each
starting from nothing.

Nothing leaves the machine. There is no server to sign up for and no account.

The most useful thing in this repo is probably [a result I retracted](#the-result-i-retracted),
because I found the flaw myself and the flaw was in my own evaluation, not in the code.

## What problem this solves

You have told your assistants the same things dozens of times. Which sibling is which. What
you already decided about the database. That you dislike driving at night. Each new session
starts blank, and each product that tries to fix this does so inside its own walls: a chat app
remembers you inside the chat app, an editor remembers you inside the editor, and neither can
see the other.

The ordinary workaround is to keep a notes file and paste it in. That fails for two reasons.
It only holds what you thought to write down, which is a tiny fraction of what actually
happened to you, and it hands the whole file to every tool at once, including tools you would
not trust with your medical appointments.

Exocortex separates the two halves of the problem. Capture is passive and broad: the log is
built from what your machine already records rather than from what you remember to type.
Access is narrow and per client: a tool asks a question, gets a bounded and sanitized answer,
and never gets a copy of the store. A coding assistant that also has shell and web access is
treated as an open world client and sees a deliberately narrower projection than the local
menu bar tool does.

The honest test for a project like this is not a benchmark. It is whether, after two weeks of
real use, you actually searched it. Everything here is built so that answer can be found in
twenty hours of work rather than two thousand.

## How it works

Four stages. Capture writes rows, the store holds and expires them, retrieval finds them two
different ways, and a nightly pass reads over the store and writes things back into it.

```
CAPTURE                        STORE                    RETRIEVAL
Messages, mail, browsers,      events.db (SQLite)       BM25 over FTS5      one ranked
files, clipboard, focused  ->  append only,        ->   (exact words)   ->  list, fused
window, iPhone backup,         one row per event        binary vector       by RRF
Claude Code transcripts        trust set on write       scan (meaning)          |
                                     |                                          |
                                     |                                          v
                                     v                                    MCP bus (stdio)
                            retention (deletes)                                 |
                            decay (hides, reversible)                           v
                                     ^                                    Claude Code and
                                     |                                    any other MCP
                            NIGHTLY PASS: segment, summarize,             client, each with
                            find contradictions, find connections,        its own permissions
                            track commitments, brief you in the morning
```

**Trust is assigned by the capture path and never by a model or a caller.** A message you wrote
is `self`. A message someone sent you is `third_party`. Text scraped out of a web page is
`untrusted`, because the accessibility tree of a web page (the structured description macOS
publishes for screen readers) says whatever the page wants it to say. A caller can ask for
`min_trust: self` and get only your own words. No component downstream can promote anything.

The two retrieval paths answer different questions and both are needed.

- **BM25** is classic keyword ranking. It scores a document by how many of your query's words it
  contains, weighted so that rare words count for more than common ones and long documents do
  not win by length alone. It is exact and fast and it fails completely when you remember the
  idea but not the words. Implemented over SQLite's FTS5 full text index, in
  [`exo/src/Store.swift`](exo/src/Store.swift).
- **Vector search** embeds text as a list of numbers positioned so that similar meanings land
  near each other, then finds neighbours. It catches paraphrase and misses exact strings. Each
  vector is stored as one bit per dimension so that comparing two of them is an exclusive-or and
  a popcount, which saturates memory bandwidth rather than compute, then a shortlist is rescored
  against fuller int8 vectors. [`exo/src/VectorIndex.swift`](exo/src/VectorIndex.swift) and
  [`exo/src/Embed.swift`](exo/src/Embed.swift).

The two ranked lists are merged with reciprocal rank fusion, which scores each document by
`1/(k + rank)` in each list and adds the scores, so a document does not need to win either list
outright to surface. Every returned row carries which path found it.

The nightly pass ([`exo dream`](exo/src/main.swift)) is where the store stops being a log. It
cuts the day into episodes at moments of prediction error, summarizes each one, looks for beliefs
that contradict each other, looks for connections between distant events, ages unused rows, and
writes a morning briefing capped at three items, because one false connection destroys trust in
all of them. Every generated line cites the row it came from, the citation column is `NOT NULL`,
and a line citing an event outside its own episode is discarded rather than stored.

### Retention and decay are different things and are kept apart on purpose

| | retention | decay |
| --- | --- | --- |
| basis | legal: a time to live per class of data | functional: how long since you used it |
| action | **deletes** the row | **hides** it. Row, text, vectors and index entry all stay |
| reversible | no | yes. Retrieving a cold row revives it |
| litigation hold | suspends it | irrelevant, since nothing is destroyed |

A decay pass that deleted would be destruction of evidence dressed up as housekeeping. A
retention pass that only hid would be a compliance failure. Separate files
([`Retention.swift`](exo/src/Retention.swift), [`Decay.swift`](exo/src/Decay.swift)), separate
commands.

## Where the memories come from

Thirteen capture sources, plus one receipt that is not a stream. The `source` column on every
row is one of these strings.

| `source` | What it captures | Permission needed | Trust assigned |
| --- | --- | --- | --- |
| `claudecode` | Claude Code terminal transcripts. Only `text` blocks: tool calls and results are most of the bytes and almost none of the meaning | none | yours `self`, model's `untrusted` |
| `imessage` | Messages history. 94.4% carry plain text, the rest need the binary `attributedBody` parser below | Full Disk Access | yours `self`, theirs `third_party` |
| `imessage.reaction` | Tapbacks, kept as a separate source so they can be excluded from summaries, where they read as if you said the words | Full Disk Access | `third_party` |
| `browser` (Safari) | History rows, opened read only so the browser's own lock is not disturbed | Full Disk Access | `untrusted` |
| `browser` (Chrome) | Same. Chrome's profile directory is now protected by macOS privacy controls, so pre-2025 guides are wrong about this | Full Disk Access | `untrusted` |
| `browser` (Brave) | Same | Full Disk Access | `untrusted` |
| `browser` (Edge) | Same | Full Disk Access | `untrusted` |
| `gmail` | Mail over a restricted OAuth scope, refresh token in the Keychain | OAuth, once | yours `self`, theirs `third_party` |
| `imap` | iCloud mail, which has no API. App specific password in the Keychain, never in argv where `ps` would show it | app specific password | yours `self`, theirs `third_party` |
| `fs` | File system events with a persisted stream position, so a restart replays rather than loses. Records that a file changed, never its contents | Full Disk Access outside home | `verified` |
| `ax.focus` | The accessibility tree of the focused window, which is how macOS describes on screen controls and text to screen readers | Accessibility | `untrusted` |
| `clipboard` | Clipboard contents. Items marked concealed by the source app (password managers) are never stored | none | `untrusted` |
| `iphone` | Encrypted iOS backup: call history, Notes, iOS Safari history, WhatsApp. Genuinely new data, not a duplicate of the Mac | backup password | mixed |
| `exclusion.suppressed` | **Not a stream.** A receipt with text length zero, recording *that* something was suppressed and never *what* | none | `own_file` |

An earlier summary of this repo claimed "14 life-log streams." That number only reaches 14 by
counting each browser separately and counting the suppression receipt as a stream. The table
above is the actual enumeration, and the receipt row is why the count is worth writing out
rather than asserting.

## The memory bus

`mcp-bus/` is a Model Context Protocol server. MCP is an open protocol for exposing tools to AI
clients: the client asks the server what tools exist, the server answers with a list of names and
argument schemas, and the client can then call them. Claude Code, and other MCP aware tools, speak
it natively. This server runs locally over stdin and stdout, with no network and no write path in
the process.

The contract is **frozen at v1.0.0** ([`mcp-bus/CONTRACT.md`](mcp-bus/CONTRACT.md), frozen
2026-08-19, version enforced by `server.py`). It defines **nine tools: six that read and three
that write**.

| Tool | What it does |
| --- | --- |
| `memory.recall` | Ranked, sanitized search. `k` hard capped at 50 |
| `memory.timeline` | Events in a time window |
| `memory.beliefs_at` | What you believed on a given date |
| `memory.commitments` | What you owe and are owed |
| `memory.context` | One bounded, budget capped, purpose scoped call at session start, instead of a dozen unbounded recalls |
| `memory.provenance` | Where a given answer came from |
| `memory.remember` | Returns `needs_approval` |
| `memory.correct` | Returns `needs_approval` |
| `memory.forget` | Returns `needs_approval` |

**The three write verbs do not write.** The write path belongs to a quarantined curator behind a
local approval interface, and neither exists yet, so all three return `needs_approval` rather
than a plausible lie. Describing this as a nine tool read surface would be wrong in both
directions: it is six read tools plus three that are gated.

The shape is defensive on purpose:

- **No mass read primitive.** The reference MCP memory server ships a `read_graph()` with no
  arguments, which is a single call full life dump. There is no equivalent here.
- **A client cannot assert its own trust.** Writes name a channel, and the server maps channel to
  trust. A `web` channel write claiming `trust: self` is reassigned to `untrusted` by the server.
- **Per client allowlists.** A credential for a small hardware display is forbidden from
  `commitments` outright, and its `k` is capped at 5.
- **Every result is marked private cache scope**, since a public scope on a life memory read is a
  breach through any shared intermediary.
- **Egress sanitisation.** Every returned string has markdown images, inline and reference style
  links, autolinks, bare URLs, `data:` URIs, HTML, and the Unicode tag block and zero width
  characters used for text smuggling stripped out. Reference style links matter specifically:
  the EchoLeak vulnerability (CVE-2025-32711) used them to dodge redaction.

## Results

Everything below is a measured number with the file it came from. Sample sizes are stated because
several of them are small enough to matter.

| Result | Value | How it was measured |
| --- | --- | --- |
| Test suites | **105 of 105 passing**, nine suites | Run 2026-08-27. See [Running it](#running-it) for the exact commands |
| Source size | 8,378 lines of Swift, 1,070 of Python, 9,448 total | `wc -l` over `exo/` and `mcp-bus/` |
| Store size | 100,106 events considered by the decay pass | [`exo/RESULTS.md`](exo/RESULTS.md) section 9.1, 2026-08-20 |
| iMessage recovery | **+31,328 messages**, taking iMessage from 26,719 to 58,047 rows | [`exo/RESULTS.md`](exo/RESULTS.md) section 5.1 |
| Paraphrase retrieval | **0.95 Recall@1 against 0.55 for BM25** | [`exo/tests/retrieval_eval.py`](exo/tests/retrieval_eval.py), n = 20. Caveats below |
| Commitment detection | **Zero false positives on 12 hand labelled messages, 4 of 6 commitments found** | [`exo/RESULTS.md`](exo/RESULTS.md) section 10.1, n = 12 |
| Memory bus invariants | 13 of 13 | [`mcp-bus/README.md`](mcp-bus/README.md), against the real store |

`mcp-bus/README.md` describes the store as 91,384 events. That is an earlier snapshot taken
before the iPhone backup ingest. The current figure is 100,106 as of 2026-08-20.

### The iMessage recovery

Messages stores most text in a plain column, but 5.6% of rows put it in `attributedBody`, a
binary Apple archive format. The usual advice is to shell out to a GPL licensed parser. Instead
this reads the format directly in about forty lines
([`exo/src/IMessage.swift`](exo/src/IMessage.swift)): 95.1% of those rows parse, 88.9% yield real
text, 6.2% are attachment only (a single object replacement character, so a photo with genuinely
no text to recover, not a failure), and 4.9% fail and are counted rather than half parsed.

Recovering them exposed a second bug worth more than the first. Ingest resumed from the newest
row it had seen, so it never revisited rows an older parser had skipped, which means **any
improvement to extraction is invisible to a system that only moves forward.** Re-running after
the fix recovered exactly one message. A `--rescan` flag now ignores the cursor, and a unique
index on `(source, external_id)` absorbs the duplicates.

### Paraphrase retrieval, and what the number does not mean

[`exo/tests/retrieval_eval.py`](exo/tests/retrieval_eval.py) holds 20 short documents on
deliberately unrelated topics (an orrery, sourdough, a GDPR case, tides, knots, soldering) and 20
queries written to describe each document while sharing as little vocabulary with it as possible.
Every query is paired to its document by construction, so the retrieval system cannot influence
the answer key.

Recall@1 is how often the correct document is the top hit. Recall@5 is how often it is in the top
five. MRR (mean reciprocal rank) averages `1 / rank of the correct document`, so it rewards being
close when you are not first.

| Method | Recall@1 | Recall@5 | MRR |
| --- | ---: | ---: | ---: |
| BM25 (keyword baseline) | 0.55 | 0.65 | 0.634 |
| 1024 bit binary vectors | 0.85 | 1.00 | 0.917 |
| 1024 bit binary plus int8 rescore | **0.95** | **1.00** | **0.975** |

**Four caveats, all of which limit this number:**

1. **n = 20.** 0.95 means 19 of 20. A single query is worth 0.05, so the gap between 0.90 and
   0.95 in this table is one query changing its mind.
2. **The finer conclusions are not statistically supported at this size.** `RESULTS.md` also
   states that the rescore tier helps at every vector width and that width helps monotonically.
   Those are the right shape and they are consistent with the data, but with 20 queries the
   differences between adjacent rows are inside the noise. Treat them as directional.
3. **The queries were deliberately built to share minimal vocabulary with their targets.** That
   is exactly the right test for paraphrase retrieval, which is the thing embeddings exist for.
   It is also the condition under which a keyword baseline does worst. 0.95 against 0.55 is a
   paraphrase result, not a general retrieval result.
4. **20 documents is a toy corpus against a 100,000 event store.** Recall degrades as a corpus
   grows and there are more near misses to beat, and the earlier rounds in `RESULTS.md` show
   exactly that happening on the real store.

### Commitment detection

`exo commitments --scan` finds promises in both directions and holds them until discharged. On a
set of twelve messages: 4 true positives, 2 false negatives, 0 false positives, 6 true negatives.
That is precision 1.00 and recall 0.67.

Two things about the methodology are worth more than the numbers:

- **The labels were written before the detector was pointed at the set**, and `RESULTS.md` says
  the retraction below is the reason.
- **Scoring was done on the stored decision, not on the model's raw flag.** Three checks run in
  code after the model answers: the quoted promise must appear verbatim in the message, it must
  contain a first person commissive marker, and the writer must be the person making the promise.
  Crediting the raw flag would have flattered the detector with answers the checks then threw
  away. Scoring the stored decision is the harder and more honest choice.

The third check exists because of a real message in this corpus: *"She said - I'll see what I can
learn on my end!!!"*. It is `trust='self'`, it contains a textbook promise, and the person making
the promise is not the writer.

**n = 12 is a smoke test, not a precision measurement.** Six of the twelve are near misses chosen
because they contain promise shaped phrasing without being promises (a request, a denial of
ability, a relayed permission, a hedge), so zero false positives on that set is meaningful in kind
but not in magnitude. Do not read 1.00 as a precision figure that would survive a thousand
messages.

## The result I retracted

[`exo/RESULTS.md`](exo/RESULTS.md) contains a section headed "CORRECTION, Round 4's conclusion was
wrong, and the cause was the evaluation," with **the retracted round kept in full underneath it.**
It is not deleted, it is not summarized away, and it is the part of this repo I would want read
first.

**The retracted claim:** that the int8 rescore tier consistently made retrieval worse, that three
separate fixes had not helped, and that the defect was real and unfound. The tier was disabled by
default on the strength of that conclusion, across three commits.

**The claim was wrong, and both defects were in the evaluation.**

1. **Ranks were compared across two different databases.** The "full precision ceiling ranks it 1
   of 2015" figure came from one database and the pipeline numbers from another, ingested over a
   different window with different sequence numbering, so the two numbers referred to *different
   gold documents*. Re-run against the same stored vectors, Python scored the gold document at
   rank 41 and Swift at rank 29. Swift was never behind Python. There was no discrepancy to
   explain and no defect to find.

2. **The gold documents were meta-commentary about the experiment.** "Gold" had been defined as
   whichever document BM25 ranked first for a rare term. But this corpus is a transcript of
   building this very system, so the top hit for `arcminute` was a 230 character message whose
   entire text reads *"At full precision `arcminute` ranks 1 of 2015."* The probe was retrieving
   the experiment's own notes.

> An eval whose ground truth comes from the thing being evaluated is not an eval.

The fix was to stop inferring the answer key and author it instead, which is where the 20 document
set above came from. With independent ground truth the rescore tier is worth +0.05 to +0.10
Recall@1 and it is enabled by default again.

The reason this is in the README rather than buried in a results file: every number in the
retracted round was real and the code did exactly what it was reported to do. The failure was
entirely in how the question was asked, it produced a confident and wrong three commit
conclusion, and it is the same methodological failure this project's own background reading had
already catalogued in published benchmarks.

## Running it

Requires macOS on Apple silicon and the Swift toolchain that ships with Xcode. Python 3 for the
memory bus and the embedding sidecar. No package manager and no third party Swift dependencies.

```bash
bash exo/build/build.sh        # single swiftc invocation, produces exo/build/exo
```

A successful build prints `built build/exo` and nothing else that matters.

The fastest way to see it work without granting any macOS permissions at all:

```bash
cd exo
./build/exo seed                       # synthetic events, proves store and search end to end
./build/exo search retention --hybrid  # BM25 and vector, fused by RRF
./build/exo stats
```

With permissions, capture and query real data:

```bash
./build/exo perms                      # report which macOS permissions are granted
./build/exo ingest --days 7            # Claude Code transcripts, needs no permissions at all
./build/exo imessage                   # needs Full Disk Access
./build/exo capture --interval 2       # focused window and clipboard loop
./build/exo bar                        # floating search panel on Control Option Space
./build/exo dream                      # the nightly pass, run now
./build/exo brief                      # the morning read out, at most three items
```

Run the test suites. Each prints its own pass count and the nine together total 105:

```bash
cd exo
for t in butler connect contra decay historian ledger promise scout segment; do
  ./build/exo $t-test
done
```

Expected output per suite: `5 passed`, `13 passed`, `15 passed`, `15 passed`, `11 passed`,
`7 passed`, `11 passed`, `18 passed`, `10 passed`. Any non zero failure count is a real
regression. These suites run against temporary databases and do not touch your store.

The memory bus needs no build:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | EXO_PURPOSE=oracle python3 mcp-bus/server.py | jq '[.result.tools[].name]'
```

To wire it into Claude Code, add to your MCP configuration:

```json
{ "mcpServers": {
    "exocortex": {
      "command": "python3",
      "args": ["/absolute/path/to/exocortex/mcp-bus/server.py"],
      "env": { "EXO_PURPOSE": "coding" }
    } } }
```

Use `EXO_PURPOSE=coding` for any client that also has web or shell access. It is treated as an
open world client and gets the narrow projection.

## Project layout

```
exo/                        The capture and cognition engine, Swift, no dependencies
├── src/
│   ├── Store.swift             SQLite schema, FTS5 index, insert path, trust column
│   ├── Embed.swift             Embedding sidecar protocol, binary and int8 encoding
│   ├── VectorIndex.swift       Binary scan, int8 rescore, RRF fusion
│   ├── Capture.swift           Focused window and clipboard loop
│   ├── Exclusion.swift         The suppression list, and the receipt it writes
│   ├── ClaudeCode.swift        Terminal transcript ingest
│   ├── IMessage.swift          Messages, including the attributedBody parser
│   ├── Browser.swift           Safari, Chrome, Brave, Edge history
│   ├── Gmail.swift, IMAP.swift Mail, OAuth and app specific password paths
│   ├── IPhone.swift            Encrypted iOS backup ingest via the Python sidecar
│   ├── FileEvents.swift        File system events with a persisted cursor
│   ├── Bar.swift               The floating search panel
│   ├── Ledger.swift            Bitemporal belief store: what you believed, and when
│   ├── Contradict.swift        Four verdict contradiction detection
│   ├── Connect.swift           Connection discovery between distant events
│   ├── Segment.swift           Cutting a day into episodes
│   ├── Promise.swift           Commitment tracking
│   ├── Butler.swift            Per person dossier
│   ├── Historian.swift         The week, when it has a story
│   ├── Scout.swift             Standing questions that rot at 60 days
│   ├── Decay.swift             Hiding unused rows, reversibly
│   ├── Retention.swift         Deleting expired rows, with receipts
│   └── main.swift              Every subcommand, and all nine test suites
├── tools/                  Python sidecars: embedding, iPhone backup, backup and restore
├── tests/retrieval_eval.py The authored ground truth retrieval evaluation
├── RESULTS.md              Every measurement, including the retraction
└── build/build.sh          The whole build

mcp-bus/                    The memory contract and its server, Python
├── CONTRACT.md             v1.0.0, frozen 2026-08-19
├── schema/tools.json       The machine checkable tool surface
├── store.py                Read only data access and egress sanitisation
├── server.py               stdio MCP server, no network, no write path
└── CHANGELOG.md            Deprecation policy: additive is minor, narrowing is major
```

## Status

Built and running locally on macOS. 31 commits. Not packaged for anyone else to install, and not
intended to be until the write path exists.

**Working:** all thirteen capture sources, the store with retention and decay, hybrid retrieval,
the belief ledger, and the nightly pass with four of five planned daemons (commitments, per person
dossiers, the weekly story, standing questions). Nine test suites, 105 checks, all passing.

**Known limits, in the order I would fix them:**

- **The store is not encrypted at rest yet.** Everything lives in one `events.db`. Splitting the
  payloads and the full text index into a separate encrypted database is designed and not built.
  A full text index over your own text is a searchable concordance of your life and belongs on
  the encrypted side.
- **Backups are local only, which is not really a backup.** `tools/backup.sh` takes a verified
  restorable snapshot, and the offsite step is written up but not running.
- **The write path does not exist.** `remember`, `correct` and `forget` return `needs_approval`.
  Building them means building the quarantined curator and the local approval interface first.
- **Contradiction recall is about half.** Detection only catches a change of mind when the model
  frames both statements as answering the same question. Reframed pairs are missed.
- **Private browsing detection is title regex only**, which is spoofable and breaks in other
  languages. The durable fix is a browser extension signalling over a local socket.
- **Unbundled executables are never captured.** A bare command line binary has no bundle
  identifier, so the exclusion check fails closed. That is the correct direction to fail, and the
  ledger records the app name so it is diagnosable.
- **One daemon is unbuilt:** an editor that rewrites text on request. It is deliberately last,
  because it is the task least suited to a small on device model.

---

Jalen Edusei, [jalenedusei.com](https://www.jalenedusei.com),
[github.com/jke48222](https://github.com/jke48222)

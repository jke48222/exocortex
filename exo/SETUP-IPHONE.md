# iPhone backup ingest

Your backup at `~/Library/Application Support/MobileSync/Backup/00008130-000414241EE8001C`
is **47 GB, iPhone16,2, iOS 27, dated 2026-07-09** — and **encrypted**, which is the right
setting to have chosen. Nothing in it, not even the file manifest, is readable without the
backup password.

## What it actually contains — measured, not assumed

`exo iphone-discover` enumerates the real manifest: **282,214 files, 1,484 databases.**
Paths are resolved from that manifest rather than hardcoded, because hardcoding is what made
Safari look absent — iOS 27 moved history to `Library/Safari/Profiles/<UUID>/History.db`.

Ingested by default (**8,934 records from this backup**):

| source | records | what it adds |
|---|---:|---|
| **Call history** | 4,576 | who, when, how long, answered/missed — nowhere else on disk |
| **WhatsApp** | 2,132 | full message text |
| **Calendar** | 1,334 | events with notes |
| **Contacts** | 686 | names, orgs, notes |
| **Notes** | 135 | titles **and bodies** (ungzipped from `ZICNOTEDATA.ZDATA`) |
| **Voicemail** | 40 | sender, duration |
| **Voice memos** | 31 | titles |
| Safari | **0** | see below |

Available but **not** ingested by default:

| source | why it's opt-in |
|---|---|
| `health` | Medical data. Filed on the **`sensitive` retention class (30 days)**, not kept forever. Ask for it by name: `--sources health` |
| `photos` | Metadata only (captions/dates); pixels never enter the log |
| `sms` | Duplicates the Mac's `chat.db`, which is already ingested and more complete |

## Safari history is genuinely absent, and that isn't a bug

Both profile databases decrypt fine, contain **exactly** the tables queried
(`history_items`, `history_visits`), and both are **0 rows** — while `history_tombstones`
has entries, so the databases are live. **iOS Safari history syncs through iCloud rather
than living in the local store**, so it simply isn't in the backup. Desktop Safari is
already covered by the `browser.safari` source.

Verified with `exo iphone-schema --sources safari`, which dumps table names and row counts
so "0 rows" can be told apart from "wrong table names" without guessing.

## First: Full Disk Access for your terminal

If you see **"Cannot read …/MobileSync/Backup"** or **"no iOS backups found"**, the folder
is there and the code is fine — macOS is denying access. iPhone backups sit behind Full Disk
Access, and **the grant belongs to whichever app is running `exo` (your terminal), not to
`exo` itself.**

1. **System Settings → Privacy & Security → Full Disk Access**
2. **+** and add your terminal app (Terminal, iTerm, Ghostty, Warp, VS Code…)
3. **Quit and reopen the terminal** — the grant only takes effect on a fresh launch

Or drag `build/exo` itself into that list to grant the binary directly.

*(This is also why the same command can work in one context and not another: a process
inherits the TCC grant of the app that launched it.)*

## Run it

```bash
./build/exo iphone-auth        # prompts, echo OFF
./build/exo iphone             # ingests calls,notes,safari,whatsapp
./build/exo iphone --sources calls,whatsapp --limit 5000
```

The password is the one you set in **Finder → your iPhone → "Encrypt local backup"**. If
you've forgotten it, it cannot be recovered — you'd have to reset it on the phone
(Settings → General → Transfer or Reset → Reset → Reset All Settings), which invalidates
every existing encrypted backup.

## How the password is handled

- **Read with `getpass(3)`** — echo disabled, read from `/dev/tty`, so it works even with
  output redirected
- **Passed to the decoder on stdin, never in argv.** Anything in argv is visible to `ps` for
  every process on the machine and lands in your shell history
- **Stored in the login Keychain** (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), nowhere
  else — not a dotfile, not the database
- Verified before it's stored, so a typo fails immediately rather than silently later

The same fix was applied to `imap-auth`, which previously took the password as an argument.

## Trust and retention

Consistent with every other source — assigned by capture path, never by a model:

| record | trust | retention |
|---|---|---|
| Your notes, calls you placed, WhatsApp you sent | `self` | forever |
| Calls you received, WhatsApp others sent | `third_party` | `correspondence`, 5 years |

Anything key-shaped (`sk-`, `AKIA`, `ghp_`, `-----BEGIN`) is dropped and logged as an
exclusion hit — recording *that* it happened, never *what*.

## Known limits

- **Note bodies are not extracted.** `ZICNOTEDATA.ZDATA` is gzipped protobuf; only titles are
  ingested. Titles are the first line of a note, so they carry most of the retrieval value,
  but this is a real gap rather than a design choice.
- **Attachments and photos are skipped** — the pixel tier is a 21-day cache by design
  (PASS-4 §3), and a 47 GB backup would blow the 228 GB budget immediately.
- Decryption uses `iOSbackup` + `pycryptodome`. The backup is opened read-only; nothing is
  written back to it.

# iPhone backup ingest

Your backup at `~/Library/Application Support/MobileSync/Backup/00008130-000414241EE8001C`
is **47 GB, iPhone16,2, iOS 27, dated 2026-07-09** — and **encrypted**, which is the right
setting to have chosen. Nothing in it, not even the file manifest, is readable without the
backup password.

## Why it's worth ingesting

It holds data that **never touches the Mac**, so it's genuinely new rather than a duplicate
of the existing sources:

| source | what it adds |
|---|---|
| **Call history** | who you spoke to, when, for how long, answered or missed — nowhere else on disk |
| **Notes** | titles from `ZICCLOUDSYNCINGOBJECT` |
| **iOS Safari** | mobile browsing, separate from desktop Safari |
| **WhatsApp** | full message text, if installed |

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

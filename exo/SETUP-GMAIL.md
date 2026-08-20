# Setting up Gmail ingest

**~10 minutes, once.** Only you can do this part — it needs your Google account.

The one thing that actually matters is **Step 5**. Get it wrong and everything works for
seven days and then silently stops.

---

## 1. Create a project

[console.cloud.google.com](https://console.cloud.google.com) → project dropdown (top left) →
**New Project** → name it `exocortex` → **Create**, then select it.

## 2. Enable the Gmail API

**APIs & Services → Library** → search **Gmail API** → **Enable**.

## 3. Configure the consent screen

**APIs & Services → OAuth consent screen**

- User type: **External** → Create
- App name: `exocortex` · User support email: your address · Developer contact: your address
- **Save and Continue**

## 4. Add the scope

On the **Scopes** step → **Add or Remove Scopes** → paste:

```
https://www.googleapis.com/auth/gmail.readonly
```

→ **Update** → **Save and Continue**.

This is a **restricted** scope, which normally implies a CASA security assessment. **You do
not need one.** Google's restricted-scope docs exempt the case where *"you are the only user
of your app or ... a few users, all of whom are known personally to you."* You are the only
user, and this is a local native client with no third-party server.

## 5. ⚠️ Publish the app — the step that matters

**OAuth consent screen → Publishing status → PUBLISH APP → Confirm.**

**Do NOT click "Submit for verification".** You want the status **"In production"** while
remaining unverified.

**Why:** in **Testing** status Google expires refresh tokens after **7 days**. An all-day
logger authorized on Monday dies the following Monday, with no error until you look. Setting
the app to In production gives **non-expiring refresh tokens**. The only cost is a one-time
"Google hasn't verified this app" interstitial — click **Advanced → Go to exocortex
(unsafe)** once, and never again.

That warning is accurate and harmless here: the unverified app is *yours*, running locally,
reading only your own mail.

## 6. Create credentials

**APIs & Services → Credentials → + Create Credentials → OAuth client ID**

- Application type: **Desktop app**
- Name: `exo`
- **Create** → copy the **Client ID** and **Client secret**

(Desktop app type enables the loopback redirect `exo` uses. You do not need to configure a
redirect URI — `exo` picks a free localhost port and tells Google which one.)

## 7. Authorize

```bash
./build/exo gmail-auth <CLIENT_ID> <CLIENT_SECRET>
```

Your browser opens; approve; the tab says *exocortex: authorized*. The refresh token is
stored in the **login Keychain** (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), not a
dotfile — a mailbox refresh token is exactly the credential the threat model says never to
leave lying in plaintext.

## 8. Connecting more than one account

The same OAuth client works for **every** Google account — just run `gmail-auth` again and
pick the other account in the browser:

```bash
exo gmail-auth <CLIENT_ID> <CLIENT_SECRET>   # sign in as the SECOND account
exo accounts                                  # list what's connected
exo gmail                                     # ingests ALL connected accounts
exo gmail --account jalenedusei@gmail.com     # or just one
```

Refresh tokens are stored per-address (`refresh_token:<email>`), and each ingested message
is keyed `gmail:<account>:<id>`, so two mailboxes can never overwrite or collide with each
other.

## 9. iCloud is different — it needs IMAP

iCloud has no Gmail-style API. It uses IMAP, and Apple requires an **app-specific
password** because your Apple ID has 2FA — your normal password will be rejected.

1. Go to **[account.apple.com](https://account.apple.com)** → **Sign-In and Security** →
   **App-Specific Passwords** → **+** → name it `exocortex`
2. Copy the generated password (looks like `abcd-efgh-ijkl-mnop`)

```bash
exo imap-auth j.edusei@icloud.com abcd-efgh-ijkl-mnop
exo imap --days 30
```

`exo` verifies the login before storing anything, and the password goes in the login
Keychain — never a file, and never argv beyond that one command.

## 10. Ingest

```bash
./build/exo gmail --limit 500                        # default: newer_than:30d
./build/exo gmail --query "newer_than:1y" --limit 5000
./build/exo gmail --query "from:someone@example.com"
```

`--query` takes ordinary Gmail search syntax.

---

## What exo does with it

| | |
|---|---|
| **Reads** | `text/plain` part of each message, walking the MIME tree; falls back to the snippet |
| **Never reads** | attachments, or anything requiring a write scope — the token is read-only |
| **Trust** | mail **you sent** → `self`. Mail **from others** → `third_party`, so it cannot influence a tool call |
| **Retention** | yours → `text` (forever). Theirs → `correspondence` (5 years) — their data, deliberately shorter |
| **Redaction** | messages containing key-shaped strings (`sk-`, `AKIA`, `ghp_`, `-----BEGIN`) are dropped and logged as an exclusion hit, recording *that* it happened, never *what* |

## If something breaks

**`invalid_grant` on refresh** — the Testing-status trap from Step 5. Set publishing status
to In production and re-run `gmail-auth`.

**`no refresh_token returned`** — Google issues one only on first consent. Revoke at
[myaccount.google.com/permissions](https://myaccount.google.com/permissions) and retry.

**Nothing ingested** — widen the window: `--query "newer_than:1y"`.

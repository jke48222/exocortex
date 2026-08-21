#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swiftc -O -swift-version 5 \
  src/Paths.swift src/Store.swift src/Embed.swift src/VectorIndex.swift src/Exclusion.swift src/Capture.swift src/ClaudeCode.swift src/Browser.swift src/IMessage.swift src/Gmail.swift src/IMAP.swift src/IPhone.swift src/FileEvents.swift src/Bar.swift \
  src/Ledger.swift src/Extract.swift src/Contradict.swift src/Connect.swift src/Segment.swift src/Decay.swift src/Promise.swift src/Butler.swift src/Historian.swift src/Retention.swift src/main.swift \
  -framework NaturalLanguage -framework CoreServices -framework AppKit -framework ApplicationServices -framework Carbon \
  -lsqlite3 -o build/exo
echo "built build/exo"

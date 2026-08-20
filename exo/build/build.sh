#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swiftc -O -swift-version 5 \
  src/Store.swift src/Embed.swift src/VectorIndex.swift src/Exclusion.swift src/Capture.swift src/ClaudeCode.swift src/Browser.swift src/IMessage.swift src/Gmail.swift src/IMAP.swift src/FileEvents.swift src/Bar.swift \
  src/Retention.swift src/main.swift \
  -framework NaturalLanguage -framework CoreServices -framework AppKit -framework ApplicationServices -framework Carbon \
  -lsqlite3 -o build/exo
echo "built build/exo"

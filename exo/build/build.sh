#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swiftc -O -swift-version 5 \
  src/exo.swift \
  -framework AppKit -framework ApplicationServices \
  -lsqlite3 \
  -o build/exo
echo "built build/exo"

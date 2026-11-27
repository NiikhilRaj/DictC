#!/bin/bash
# Builds DictC.app in this folder and opens it. `./build.sh install` puts it in
# /Applications instead and opens that copy. Needs Xcode Command Line Tools
# (run `xcode-select --install` once if `swiftc` is missing).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Run: xcode-select --install   then run this script again."
  exit 1
fi

APP="DictC.app"
pkill -x DictC 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework WebKit -framework Carbon -framework CoreAudio \
  Sources/main.swift -o "$APP/Contents/MacOS/DictC"

cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signing normally identifies the app by the hash of this exact build,
# so macOS forgets the Accessibility permission on every rebuild. Naming the
# app by its bundle identifier instead lets the permission carry over.
codesign --force --sign - -r='designated => identifier "local.dictc.app"' "$APP"

if [ "${1:-}" = "install" ]; then
  rm -rf "/Applications/$APP"
  mv "$APP" "/Applications/$APP"
  echo "Installed /Applications/$APP"
  open "/Applications/$APP"
else
  echo "Built $(pwd)/$APP"
  open "$APP"
fi

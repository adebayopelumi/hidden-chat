#!/bin/zsh
# Builds HiddenChat.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="HiddenChat.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O Theme.swift ChatList.swift Config.swift OpenAI.swift Claude.swift Tools.swift Screen.swift AreaPicker.swift Highlights.swift Listening.swift Questions.swift main.swift -o "$APP/Contents/MacOS/HiddenChat"
codesign --force --sign - "$APP"   # ad-hoc signature so macOS can remember its permissions
echo "Built $PWD/$APP"

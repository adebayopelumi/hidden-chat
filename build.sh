#!/bin/zsh
# Builds HiddenChat.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="HiddenChat.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O Theme.swift ChatList.swift Config.swift OpenAI.swift Claude.swift Tools.swift Screen.swift AreaPicker.swift Highlights.swift Listening.swift Questions.swift main.swift -o "$APP/Contents/MacOS/HiddenChat"
codesign --force --sign - "$APP"   # ad-hoc signature so macOS can remember its permissions

# Move it into Applications, so it opens like any other app (Spotlight, Launchpad, Dock).
# Only one copy is kept, so Spotlight doesn't list it twice.
if [[ -w /Applications ]]; then
  rm -rf "/Applications/$APP"   # replace, rather than overwrite a copy that may be running
  ditto "$APP" "/Applications/$APP"
  rm -rf "$APP"
  echo "Installed /Applications/$APP"
else
  echo "Built $PWD/$APP (couldn't write to /Applications; drag it there yourself)"
fi

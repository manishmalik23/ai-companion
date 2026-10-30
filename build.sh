#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")" && pwd)"
app_dir="$project_root/dist/Agent Companion.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$project_root/.build/module-cache"
cp "$project_root/desktop/Resources/PipSpriteSheet.png" "$app_dir/Contents/Resources/PipSpriteSheet.png"
mkdir -p "$app_dir/Contents/Resources/Characters"
for character in Sunny Mochi Boba Lumi Mallow Sprout; do
  test -f "$project_root/desktop/Resources/Characters/$character.png"
  test -f "$project_root/desktop/Resources/Characters/${character}Blink.png"
done
for character in PeachPuff LavenderMochi MintBean Nimbo Chai Plumo; do
  test -f "$project_root/desktop/Resources/Characters/$character.png"
done
test -f "$project_root/desktop/Resources/Characters/FluffyLayouts.json"
cp "$project_root/desktop/Resources/Characters/"*.png "$app_dir/Contents/Resources/Characters/"
cp "$project_root/desktop/Resources/Characters/FluffyLayouts.json" "$app_dir/Contents/Resources/Characters/FluffyLayouts.json"
session_links="$project_root/vscode-session-links/artifacts/pip-session-links-0.3.0.vsix"
if [[ -f "$session_links" ]]; then
  cp "$session_links" "$app_dir/Contents/Resources/PipSessionLinks.vsix"
else
  rm -f "$app_dir/Contents/Resources/PipSessionLinks.vsix"
fi
swiftc -O -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/desktop/Models.swift" "$project_root/desktop/SessionHeader.swift" "$project_root/desktop/PointingHandButton.swift" "$project_root/desktop/RobotArt.swift" "$project_root/desktop/CreatureCharacters.swift" "$project_root/desktop/Appearance.swift" "$project_root/desktop/Questions.swift" \
  "$project_root/desktop/ProviderApps.swift" "$project_root/desktop/BubbleDesign.swift" "$project_root/desktop/DesktopChatObserver.swift" \
  "$project_root/desktop/AppRuntime.swift" "$project_root/desktop/AppInstallation.swift" "$project_root/desktop/Setup.swift" "$project_root/desktop/SessionNavigation.swift" \
  "$project_root/desktop/Chat.swift" "$project_root/desktop/ApprovalReceiver.swift" "$project_root/desktop/Companion.swift" \
  -o "$app_dir/Contents/MacOS/AgentCompanion"
swiftc -O -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/desktop/RobotArt.swift" "$project_root/desktop/CreatureCharacters.swift" "$project_root/desktop/Icon.swift" -o "$project_root/.build/icon-generator"
"$project_root/.build/icon-generator" "$project_root/.build/Pip.iconset" "$app_dir/Contents/Resources/Pip.icns" \
  "$project_root/desktop/Resources/PipSpriteSheet.png"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentCompanion</string>
<key>CFBundleIdentifier</key><string>dev.local.agent-companion</string>
<key>CFBundleName</key><string>Pip</string>
<key>CFBundleDisplayName</key><string>Pip</string>
<key>CFBundleIconFile</key><string>Pip.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.2</string>
<key>CFBundleVersion</key><string>46</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Pip selects the existing Terminal tab for the agent request you click. It does not run commands or read terminal output.</string>
</dict></plist>
PLIST
printf 'Built %s\n' "$app_dir"

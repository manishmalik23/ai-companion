#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build/module-cache
python3 -B -m unittest discover -s tests
./build.sh
python3 -B scripts/check_fresh_install.py
check_swift() {
  local check_name="$1"
  shift
  swiftc -O -module-cache-path .build/module-cache "$@" -o ".build/$check_name"
  ".build/$check_name"
}
check_swift runtime-checks desktop/Models.swift desktop/RuntimeChecks.swift
check_swift session-handoff-checks desktop/Models.swift tests/SessionHandoffChecks.swift
check_swift app-runtime-checks desktop/AppRuntime.swift tests/AppRuntimeChecks.swift
check_swift app-installation-checks desktop/AppRuntime.swift desktop/AppInstallation.swift tests/AppInstallationChecks.swift
check_swift action-detail-checks desktop/Models.swift tests/ActionDetailChecks.swift
swiftc -O -module-cache-path .build/module-cache desktop/AppRuntime.swift desktop/ApprovalReceiver.swift tests/ApprovalReceiverChecks.swift -o .build/approval-receiver-checks
.build/approval-receiver-checks "$(python3 -c 'import sys; print(sys.executable)')"
check_swift desktop-chat-observer-checks desktop/Models.swift desktop/ProviderApps.swift desktop/DesktopChatObserver.swift desktop/DesktopChatObserverChecks.swift
check_swift conversation-state-checks desktop/Models.swift desktop/ProviderApps.swift tests/ConversationStateChecks.swift
check_swift bubble-design-checks desktop/Models.swift desktop/ProviderApps.swift desktop/RobotArt.swift desktop/CreatureCharacters.swift desktop/BubbleDesign.swift tests/BubbleDesignChecks.swift
check_swift creature-character-checks desktop/RobotArt.swift desktop/CreatureCharacters.swift tests/CreatureCharacterChecks.swift
check_swift appearance-checks desktop/RobotArt.swift desktop/CreatureCharacters.swift desktop/Appearance.swift tests/AppearanceChecks.swift
check_swift companion-dock-checks -D PIP_COMPANION_CHECKS desktop/Models.swift desktop/SessionHeader.swift desktop/PointingHandButton.swift desktop/RobotArt.swift desktop/CreatureCharacters.swift desktop/Appearance.swift desktop/Questions.swift desktop/ProviderApps.swift desktop/BubbleDesign.swift desktop/DesktopChatObserver.swift desktop/AppRuntime.swift desktop/AppInstallation.swift desktop/Setup.swift desktop/SessionNavigation.swift desktop/Chat.swift desktop/ApprovalReceiver.swift desktop/Companion.swift tests/CompanionDockChecks.swift
check_swift codex-hook-checks desktop/Models.swift desktop/ProviderApps.swift tests/CodexHookActivityChecks.swift
check_swift robot-animation-checks desktop/RobotArt.swift desktop/CreatureCharacters.swift tests/RobotAnimationChecks.swift
check_swift session-navigation-checks desktop/Models.swift desktop/SessionNavigation.swift tests/SessionNavigationChecks.swift
check_swift session-header-checks desktop/Models.swift desktop/SessionHeader.swift tests/SessionHeaderChecks.swift
check_swift action-button-checks desktop/PointingHandButton.swift tests/ActionButtonChecks.swift
if [[ "${PIP_CHECK_INTERACTIVE_FOCUS:-0}" == 1 ]]; then
  check_swift question-focus-checks desktop/Models.swift desktop/Questions.swift tests/QuestionFocusChecks.swift
fi

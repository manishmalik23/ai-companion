# Contributing to Pip

Pip is a private macOS beta. Ask the repository owner for access and accept the
GitHub invitation before cloning. Submit changes through a pull request to
`master`; keep each change focused enough to review independently.

## TypeScript source development

For the shared Electron interface and experimental native Windows source path,
follow [cross-platform/README.md](cross-platform/README.md). Use Node.js 24 and
Yarn 1.22.22, then run `yarn install --frozen-lockfile`, `yarn test` and
`yarn smoke` from `cross-platform/`. `yarn start` runs the app from
source. It has a separate private runtime and does not alter real agent settings
until a reviewed connection is applied. Do not run the checks against your real
agent configuration or describe Windows as tested without native acceptance.

This source workflow does not package a Pip Windows app or installer. The
native Swift implementation remains in place. The following setup is for that
Mac implementation.

The source workflow can build/install the separate **Pip Session Links 0.3.0**
VS Code extension with `yarn session-links:install`, or build a reviewable VSIX
with `yarn session-links:build`. This is extension packaging, not a Windows app
installer. Pip Source 0.7.2-alpha.3 and the native Mac 0.7.2 app use helper 0.3.0.
Helper 0.3.0 supports local native Windows and macOS VS Code windows;
native Windows acceptance is still required. The installer uses a known VS Code
application's CLI with literal arguments, not a shell or `code.cmd`.

## Set up

To build a local Mac DMG, you need macOS 13+, installed Python 3.11+ with its
full licence file, Xcode Command Line Tools, Node 20+ and Yarn 1.22.22. Clone the private
repository and run the installer builder:

```sh
git clone https://github.com/manishmalik23/ai-companion.git
cd ai-companion
./build-installer.sh
```

The command checks prerequisites and prints setup guidance without installing
global tools. It uses the installed Python, a project-local environment with
locked packaging dependencies, and the Yarn-built helper; approved npm and PyPI
access are needed. It does not use the portable-Python GitHub release bootstrap.
The DMG targets your Mac and can require a newer macOS than the official release
because of its Python runtime. It opens for manual drag-to-Applications
installation and launch; use `--no-open` to skip opening it. No app installation
or hook changes happen during the build. See [DISTRIBUTION.md](DISTRIBUTION.md#build-a-local-mac-installer).

For native development without packaging, run from the same folder:

```sh
./build.sh
./run.sh
```

The development launcher uses the checkout's own `.runtime` mailbox. Keep just
one Pip instance running. Live assistant integration requires your own installed,
signed-in Claude Code or Codex, supported local hooks, and any required hook trust.
Follow README.md for installation; hook files do not need manual editing.
Build and automated checks can run without provider credentials.

The current private-beta version is **0.7.2 / build 46**, with request handoff
after successful navigation, Claude saved-title
metadata lookup, thirteen character choices including Default Pip, full-tile
gallery selection, cached native previews, direct Mini Chat access and
**Pip Session Links 0.3.0** (`pip-local.pip-session-links`). The helper's automated checks and fresh
window-bound connection were verified locally after reloading VS Code. Apple
Terminal tab navigation and physical hand-cursor hover on a Codex header passed
manual user checks. Returning to the exact originating VS Code chat remains a
live acceptance step. Fixture checks alone do not establish live navigation.

The direct **Mini Chat** hover button is native Mac scope. Its provider picker
uses the installed **Claude Code** or **Codex CLI**, with conversations and
workspaces separate from desktop/editor chats. The TypeScript source version is
0.7.2-alpha.3; this change does not port a chat backend to it.

For the VS Code session-link helper, maintainers also need Node 20+ and Yarn
1.22.22. From the repository root, build/test/package it before rebuilding the native
app or creating a self-contained release:

```sh
cd vscode-session-links
yarn install --frozen-lockfile
yarn build
yarn test
yarn package
cd ..
./build.sh
```

The native app can build without the VSIX and may then omit it. Self-contained
release packaging requires the VSIX. The helper has no runtime npm dependencies;
prebuilt users do not install Node or Yarn. Its private package and protocol are
documented in [vscode-session-links/README.md](vscode-session-links/README.md).

## Make a change

Start from the current `master` branch with a clean working tree:

```sh
git switch master
git pull --ff-only
git switch -c feature/describe-your-change
```

Use a `fix/` branch for bug fixes or `docs/` for documentation updates if useful.
Do not push changes directly to `master`.

## Code layout

| Location | Responsibility |
| --- | --- |
| `cross-platform/` | Source-run Electron/TypeScript companion, Node hooks, renderer, character picker and experimental Windows path |
| `desktop/Companion.swift` | App lifecycle, pet controls, approval UI |
| `desktop/RobotArt.swift` | Sprite rendering, idle/working/waiting animation |
| `desktop/CreatureCharacters.swift` | Built-in catalog, pose crops and character-specific blink regions |
| `desktop/Appearance.swift` | Character selection, persistence and reset |
| `desktop/Resources/Characters/` | Artwork for twelve gallery characters, plus shared fluffy-atlas crop metadata |
| `design/characters/` | Character concepts and image-generation prompt provenance |
| `desktop/Models.swift` | Private mailbox, decision validation and session header presentation |
| `desktop/SessionHeader.swift` | Clickable subjects, system cursor and session-ID copy menu |
| `session_titles.py` | Exact-session title metadata lookup with bounded Claude title-record extraction |
| `bridge.py` | Hook parsing, correlation, session metadata, request/decision exchange |
| `desktop/SessionNavigation.swift` | Source-specific navigation, window leases, and live terminal identity validation |
| `vscode-session-links/` | TypeScript/Yarn private VS Code helper for window-bound session links and existing terminal selection |
| `setup_hooks.py` | Hook definitions |
| `install_local.py` | Reviewed installation, settings merge and backups |
| `connections.py`, `desktop/Setup.swift` | Reviewed first-launch connections for prebuilt downloads |
| `pip_helper.py`, `desktop/AppRuntime.swift` | Bundled runtime dispatch and bundle-relative executable lookup |
| `desktop/AppInstallation.swift` | Reviewed move to Applications, signature verification, recoverable replacement |
| `scripts/bootstrap_package.py`, `scripts/package_macos.py` | Portable build runtime, self-contained DMG/ZIP, signing and notarization |
| `telemetry.py`, `desktop/ApprovalReceiver.swift` | Local Claude decision synchronization |
| `desktop/Chat.swift`, `chat_bridge.py` | Isolated CLI mini-chat |
| `desktop/DesktopChatObserver.swift` | Optional Claude desktop Accessibility reader |
| `tests/`, `desktop/*Checks.swift` | Automated fixtures and checks |

## Validate

For code changes, run:

```sh
./scripts/check.sh
```

It builds Pip, runs the Python/native checks, and tests the real app installation
in a disposable home and project. It does not send model messages or change your
real assistant settings. UI changes also need a manual check in light and dark
appearance. For approval/lifecycle changes, test relevant real host behavior and
describe any host/version limits. State clearly if a manual check was unavailable.
Documentation-only changes need link/command review, not a full application rebuild.

For character-gallery changes, check all twelve built-ins and the default robot in
light and dark appearance. Previewing a tile must leave the current desktop
character unchanged until **Use character** is selected. Check idle, laptop work,
blink and waiting states. The earlier six keep fixed poses during eye blinks;
the new six play their supplied frames at a fixed center, baseline and scale,
without robot-specific eye/sparkle overlays. Verify every tile and the apply/reset
controls are reachable on smaller displays. Verify selection after restart,
switching back to the default, and custom
image import after selecting a built-in. Include native persistence checks for
version 2 catalog identifiers and existing version 1 custom profiles. Record
manual checks separately from offscreen renderer fixtures.

For native hover controls and Mini Chat changes, check all three buttons remain
reachable and drag behavior is preserved. **Claude** and **ChatGPT** still open
their installed desktop apps; **Mini Chat** opens the existing controller
directly. Verify provider switching, input focus, Enter/Command+Enter sending,
Shift+Enter newlines and New conversation. Use disposable fake-CLI fixtures for
fresh-session and workspace isolation checks. Record a real signed-in model
roundtrip only if it was explicitly exercised.

New fluffy sheets and their shared frame bounds live in
`desktop/Resources/Characters/`. After replacing one of these PNGs, regenerate
and review the metadata before testing either app:

```sh
swift -O -module-cache-path .build/module-cache design/characters/measure_fluffy_layouts.swift
```

The measurement rejects character content clipped at cell boundaries. Keep the
generation prompts and asset hashes in `design/characters/` up to date. macOS
copies `FluffyLayouts.json` into its app bundle; the TypeScript build embeds the
same JSON while retaining its restrictive renderer content security policy.

For changes to question text input, run the focus regression check on a Mac with
an unlocked desktop:

```sh
PIP_CHECK_INTERACTIVE_FOCUS=1 ./scripts/check.sh
```

This also opens a temporary question panel, selects **Other**, and checks keyboard
focus, text entry, scrolling, and preservation of the draft. It uses sample text
and does not send anything to an assistant. The normal check run skips this
interactive focus test so background validation does not interrupt your typing.

For session-header changes, check normal and long subjects, labelled **Task:**
fallbacks, provider/workspace context, hidden-but-copyable UUIDs, hand/arrow
cursors on inactive panels, and light/dark appearance. Approval reasons should
appear once near the top, with action/tool input in the scrolling details. Title
lookup must stay limited to exact-session title metadata; never use transcript bodies or raw
prompts. Live navigation also needs source-specific checks:

- Install the bundled helper through **Connect VS Code session links…**, then
  finish active work, run **Developer: Reload Window**, then run **Pip: Refresh
  Session Links** in the relevant local VS Code window.
- Verify the intended Claude Code chat or existing integrated terminal receives
  focus without a new terminal, agent command, or new agent task. The helper
  uses window-bound links and existing terminal PIDs; it does not read chat or
  project file contents.
- Verify the documented Codex desktop local-thread route independently from
  Claude's VS Code route and the version-gated Codex IDE adapter. The latter is
  currently enabled only for extension 26.1021.22027; verify the installed route
  and window binding before allowing another version. Test extension updates
  during URI resolution and preserve existing Claude/terminal capabilities.
- For Apple Terminal, verify live origin PID/start-time/TTY matching and the
  first-click Automation consent or denial path. Do not confuse this with the
  optional desktop reader's Accessibility permission.
- Check missing, stale, ambiguous, remote, daemon, unknown, and iTerm2 contexts
  remain unavailable without guessing another session or running a CLI resume.

Pure helper/native fixtures do not establish end-to-end host behavior. Record
the live host/version, connection availability, and exact navigation result in
the PR and release record; leave unperformed checks explicitly unverified.

For session handoff, both apps must retire only the exact clicked request after
navigation succeeds. New permission requests advertise `canDefer`; handoff must
return no host allow/deny decision. Existing Claude question defer behavior stays
separate from dismissal of Codex question notices, whose answers remain in the
source host. Check another queued request remains answerable and Pip collapses
only when the queue is otherwise empty. Failed navigation, a changed/expired
request or an older permission request without `canDefer` must not silently
discard a live card. Cover these races with fixtures and record live Codex
fallback-prompt acceptance separately; it is not established by fixture success.

Never commit `.runtime`, `.build`, `dist`, generated install plans, chat histories,
tokens, credentials, or local settings. Existing `.gitignore` excludes generated
state. Use synthetic payloads in tests. Include asset provenance and appropriate
reuse permission when adding art; the previous OpenAI robot stays excluded.

Keep permission behavior unchanged unless the PR explicitly explains the change:
only the matching request receives a decision; Pip never executes tool commands;
an unavailable companion must not silently approve. Preserve unrelated settings
and custom character profiles during installation and updates.

## Submit

```sh
git status --short
git add <files-you-changed>
git diff --cached
git commit -m "Describe the resulting behavior"
git push -u origin feature/describe-your-change
```

Replace the file placeholder and branch name with your actual files and branch.
Open a pull request targeting `master`. Use `.github/pull_request_template.md` as the PR outline. Explain the trigger,
resulting behavior, validation, and remaining limitations. Add screenshots for
visible UI changes. The owner reviews and merges the change after checks pass.

Before reporting a bug, include OS/Pip/provider versions, a minimal reproduction,
expected/actual behavior, and a screenshot or sanitized diagnostic if useful.
Do not post credentials or private chat/command content.

## Current beta limits

Read RELEASE_CHECKS.md before starting. Native picker acceptance and another-Mac
validation are still pending. Ordinary ChatGPT desktop conversation reading is
unavailable. Stable Developer ID signing/notarization is deferred; local updates
can require refreshing Accessibility. Apple Terminal navigation has a separate
Automation grant. Exact-chat navigation in VS Code still needs live acceptance;
remote, daemon, iTerm2, and unverified Codex IDE versions are unavailable.
The native Swift app has no Windows build. The separate TypeScript source app
and helper implement an experimental Windows path. Windows CI covers the private
lease lifecycle and rejection of unprotected directories/junctions; real native
installation, UI focus and live assistant navigation still need manual acceptance.

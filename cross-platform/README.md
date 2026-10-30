# Pip Source — TypeScript companion

Pip Source **0.7.2-alpha.3** brings Pip’s desktop approval workflow to a shared
Electron and TypeScript codebase. Run it locally with **Node.js 24** and
**Yarn 1.22.22**. This folder provides source code, not a Pip installer or a
packaged Windows executable.

The native Swift/AppKit [Pip 0.7.2 beta 2 Mac DMG](https://github.com/manishmalik23/ai-companion/releases/download/pip-v0.7.2-beta.2/Pip-0.7.2-macos-arm64.dmg)
remains the recommended Mac installation. Pip Source is an alpha based on its
interface and core approval workflows. **Windows desktop interaction and live
assistant navigation still need manual acceptance.** Component CI includes native
Windows private-file checks; do not describe it as a fully verified Windows
release or a complete replacement for the native Mac app.

The gallery includes **Peach Puff**, **Lavender Mochi**, **Mint Bean**,
**Nimbo**, **Chai** and **Plumo**, bringing the gallery to thirteen choices
including **Default Pip**. The new characters blink slowly, type at a laptop
while an agent works and use an attentive waiting animation. The selected
character is saved locally; **Reset to default** restores the original robot.
It also retries transient Windows mailbox rename locks within a bounded window,
preserving atomic replacement and rejecting changed files or directories.
Version 0.7.2-alpha.3 adds handoff of the clicked request after successful
session-header navigation, matching the native Mac app.

## Run from a repository clone

You need Git, Node.js 24, Yarn 1.22.22, repository access, and an installed,
signed-in Claude Code or supported local Codex host for the corresponding hooks.
The TypeScript app does not require Python or Xcode.

These helper setup steps require Source 0.7.2-alpha.1 or later.

From Terminal on macOS or **native PowerShell on Windows**:

```sh
git clone https://github.com/manishmalik23/ai-companion.git
cd ai-companion/cross-platform
yarn install --frozen-lockfile
yarn session-links:install
yarn start
```

Use a local folder that you intend to keep: agent hooks reference the checkout’s
absolute path. `yarn start` builds the code and launches Pip Source. Keep that
terminal open while it runs. Reopen it later by returning to this folder and
running `yarn start` again. The tray/menu-bar icon also has **Show Pip Source** and
**Quit Pip Source** actions.

`session-links:install` is the separate, optional VS Code helper setup for
clickable chat headers. It builds Pip Session Links 0.3.0 from this checkout and
installs the VSIX into the existing local VS Code application. It does not install
VS Code or an AI agent. Skip this command if you do not want session navigation;
approval hooks work independently. See the setup below for profiles, Insiders
and manual installation.

If PowerShell reports that `yarn.ps1` cannot run, use `yarn.cmd` for the same
commands, for example:

```powershell
yarn.cmd install --frozen-lockfile
yarn.cmd session-links:install
yarn.cmd start
```

Do not change the machine’s execution policy for Pip. If Node, Yarn, Git or
Electron is restricted, follow your organization’s approved installation process.
Dependency installation downloads Electron’s platform runtime. On Windows that
runtime includes `.exe` files and DLLs even though this project does not build a
Pip installer. Running from source still follows the organization’s software and
security policies.

## Connect local agent sessions

Starting Pip does not edit your assistant settings. Finish active agent actions
before switching connections between the native Mac app and Pip Source.

1. Start Pip Source.
2. Open its tray/menu-bar menu and choose **Agent connections…**.
3. Review the hook summary and choose **Connect**.
4. In Codex, open `/hooks`, review Pip’s definitions and trust them. Start or
   resume a supported local session after the review.
5. Reload or restart Claude Code after its current work finishes. For the VS Code
   extension, reload its window when it is safe to do so.

The connection replaces recognized Pip hook commands, preserves unrelated hooks
and settings, and saves backups. It also configures Claude’s permission-decision
metadata for Pip’s authenticated loopback receiver. If you already use a different
Claude telemetry destination or headers setup, connection refuses to overwrite it
and asks for a separately reviewed configuration.

To review and connect from the command line instead, use another terminal in this
folder while Pip Source runs:

```sh
yarn build
yarn connect:prepare
yarn connect:apply
```

`connect:prepare` prints a change summary and records the current configuration
hashes. It does not apply the assistant-setting changes. `connect:apply` refuses
if the settings, runner, configuration locations or prepared plan changed. Review
the printed summary before applying. The same Codex trust and Claude reload steps
still apply.

To print the generated hook JSON without connecting:

```sh
yarn hook:config --source claude
yarn hook:config --source codex
```

On Windows, generated command hooks, including Codex hooks, use PowerShell’s
`-EncodedCommand` transport for the fixed launcher and its arguments. The tool
command displayed in an approval card is never inserted into that launcher.
Share the generated hook JSON and `src/platform-config.ts` with your IT/security
team for review before connecting if your organization requires it. The source
workflow follows the same software-execution policy as other local tools.

Configured local `CLAUDE_CONFIG_DIR` and `CODEX_HOME` overrides must remain the
same during preparation, application and restoration. Native Windows local
sessions are the intended Windows target. WSL, SSH, remote VS Code sessions, dev
containers and network configuration homes are unsupported in this alpha.

## Install Pip Session Links in VS Code

Pip Session Links is our separate private extension, not a Claude/Codex feature
or a Marketplace listing. After installation, find **Pip Session Links** in the
Extensions view (**Ctrl+Shift+X** on Windows, **Cmd+Shift+X** on macOS). It does not
add a Chat Agent or sidebar icon.

From this source folder, with Yarn dependencies installed:

```sh
yarn session-links:install
```

The command checks the helper identity and pinned build tools, installs its
dependencies with the lockfile, builds `pip-session-links-0.3.0.vsix`, then invokes
the existing VS Code CLI. It uses literal process arguments, without `code.cmd`
or a shell. The generated `.vsix` is a VS Code extension archive, not a Pip app
installer or a Windows executable.

For VS Code Insiders or a named existing profile, use the corresponding options:

```sh
yarn session-links:install --insiders
yarn session-links:install --profile "Work"
```

Use the exact profile name that runs your agent; VS Code can create a new empty
profile if a name is misspelled. Standard local VS Code installation locations
are detected. For a portable/custom installation, or to review/install the
archive yourself:

```sh
yarn session-links:build
```

In your intended VS Code window/profile, run **Extensions: Install from VSIX…**
and select the printed path, normally
`../vscode-session-links/artifacts/pip-session-links-0.3.0.vsix`.
After active agent actions finish, run **Developer: Reload Window**, then
**Pip: Refresh Session Links** in each local window. A successful refresh reports
that links were refreshed for that window. Start new agent processes after the
helper is active so they inherit its window identity; finish existing work before
restarting an agent. Replacing or pulling source alone does not update an already
installed VS Code extension: rerun `yarn session-links:install` when it changes.

On Windows the helper and Pip share leases under
`%LOCALAPPDATA%\Pip\SessionLinks`. Built-in Windows PowerShell checks ownership,
private ACLs and reparse points. Existing unsafe locations are rejected rather
than silently changing their permissions. If refresh reports unavailable, select
**Pip Session Links** in **View → Output** for its static failure category. Local
native Windows VS Code is supported by the code; WSL/SSH/dev-container windows
remain unsupported. Live Windows installation and navigation are still untested.

Claude Code's session links and Codex's compatibility adapter remain separate.
The Codex adapter accepts extension version **26.1021.22027** only. Other versions
do not expose a Codex link until their route is verified; this does not disable
Claude links or approval cards. See the [helper guide](../vscode-session-links/README.md).

For the first Windows acceptance test:

1. Use a normal local Windows VS Code window and the agent's existing profile.
   Confirm **Pip Session Links 0.3.0** appears under Extensions and that **Pip:
   Refresh Session Links** succeeds after a safe reload.
2. Start a new supported Claude Code session after the helper is active. Trigger
   an ordinary permission request under its existing settings. Click the Pip
   card's title and confirm it focuses that exact conversation without answering
   the request or creating a new agent task. After successful navigation, only
   that card should leave Pip and the host's normal approval flow should resume.
3. Repeat with two VS Code windows and two sessions. Each card must return to
   its original window/chat. A closed window, ambiguous origin or unsupported
   host/version must leave navigation unavailable instead of guessing.
4. Verify Codex separately only with the supported extension version. Record the
   Windows, VS Code, helper and agent versions and the exact result. Passing
   automated fixtures or native ACL checks does not establish this live focus
   behavior.

## Everyday use

Drag the character to move it. The short line immediately below it reveals
**Claude**, **ChatGPT** and **Appearance** on hover. The character stands while
idle, blinks slowly and uses a stationary laptop pose while an agent works.
Colors follow the system’s light/dark setting, and reduced-motion preferences
stop animation.

Approval cards put the supplied reason above the command or file details. Use
**Yes, allow once** or **No, reject** for supported permission requests. You can
return a new request to the original agent by successfully opening its session
header, without allowing or denying it. The queue arrows switch between pending
requests without mixing decisions or losing question drafts.

Claude’s structured question cards support single or multiple choices and an
**Other** text field. Answer every question, then choose **Send answer**. **Answer
in source** returns control to Claude’s normal question flow. Codex questions and
other notice-only events remain alerts: answer those in their original host.
**Dismiss alert** only hides the alert in Pip; it does not answer or approve it.

The session subject appears at the top. A header becomes a clickable link only
when Pip has a supported, unambiguous destination. A workspace name or session ID
alone is not enough to guess an exact chat window.

After successful navigation, Pip hands off only the clicked card. New permission
requests return no allow or deny decision so the host can resume its normal
approval flow. Claude structured questions use their existing defer path; Codex
question notices are only dismissed in Pip, and their answers stay in the
original host. Other queued requests remain answerable. Pip collapses to the
character only when no other cards remain. Failed navigation or an older
permission request without handoff support keeps the card available and shows
an error. Fixtures cover these outcomes; live Codex fallback-prompt behavior and
Windows desktop acceptance remain unverified.

Claude subjects use saved title metadata for the exact session. Pip checks its
custom-title sidecar and bounded `custom-title` / `ai-title` records in the first
and last 64 KiB of the session file. It skips chat-message and summary records.
When no title is available in those windows, the header keeps its labelled
`Task:` fallback. Workspace context remains a separate secondary line.

Codex subjects come from the last 256 KiB of its title-only
`session_index.jsonl`, matched to the exact session UUID. The TypeScript alpha
does not yet have the native app's read-only SQLite name fallback. Workspace-only
labels and UUID/technical-ID labels cannot replace a subject, whether supplied
by a hook, saved metadata or cache. Valid explicit host titles take priority over
saved metadata, which takes priority over a valid cached subject.

### Characters

Open **Appearance** from the hover controls or tray menu. The gallery includes
**Default Pip**, **Sunny**, **Mochi**, **Boba**, **Lumi**, **Mallow**, **Sprout**,
**Peach Puff**, **Lavender Mochi**, **Mint Bean**, **Nimbo**, **Chai** and **Plumo**.
Scroll to see every choice. Preview **Idle**, **Working** or **Waiting**, then
choose **Use character**. **Reset to default** restores the original robot at
any time. Previewing does not replace your current character until you apply it.

The new six use transparent animation sheets with a slow blink, gentle laptop
typing and a waiting expression. Both apps use the same validated frame bounds
to keep their centers, scale and baselines anchored. The build embeds the local
layout metadata in the renderer; character changes require no network access.
The earlier six retain their existing standing/laptop poses and eye patches.

You can also import a PNG/WebP still image or a supported animated sheet, up to
10 MB. Custom character data and the selected built-in character stay in your
local Pip Source runtime. The build reuses the parent project’s original artwork;
see [asset provenance and formats](../ASSETS.md). It does not duplicate those
source PNGs into another tracked folder.

### Opening desktop chat apps

On macOS, Pip first looks for Claude or ChatGPT in the standard Applications
folders. On Windows, use the tray menu’s **Choose Claude desktop app…** or
**Choose ChatGPT desktop app…** and select the existing installed application’s
`.exe`. The hover buttons can then open the selected app. Pip does not download
or install those applications.

These buttons launch applications. Desktop chat content reading, live response
bubbles and the native Mac mini-chat fallback have not been ported.
The native Mac app's direct **Mini Chat** hover button does not add a chat
backend to Pip Source 0.7.2-alpha.3.

## Implemented scope and verification

Shared code and automated fixtures run on macOS and Windows CI. The Windows
helper fixture exercises actual private-ACL directory creation and lease
write/replacement/removal. These checks do not verify the desktop UI, actual
VS Code extension installation or navigation to a live assistant conversation.

| Capability | TypeScript implementation | Windows status |
| --- | --- | --- |
| Draggable pet, hover controls, system theme and reduced motion | Implemented | Native interaction untested |
| Default robot and twelve additional characters, blinking, laptop work and waiting previews | Implemented | Rendering/native display untested |
| Character selection, reset and custom import | Implemented | Native picker and persistence untested |
| Correlated permission approvals and multiple-request queue | Implemented and covered by local fixtures | Real agent integration untested |
| Claude questions, **Other** typing, multi-select and defer | Implemented and covered by fixtures | Real agent interaction untested |
| Codex question notices and notice dismissal | Implemented and covered by fixtures | Real agent integration untested |
| Clearing Claude cards after decisions in the original host | Local decision receiver and correlated retirement implemented and tested with fixtures | Live host/export timing untested |
| Opening installed Claude/ChatGPT apps | Mac discovery and user-selected app paths implemented | Selecting/launching an existing `.exe` untested |
| Exact VS Code session links | Optional helper 0.3.0 installation and window-bound routes for local macOS/native Windows, with supported host versions | Implemented; real installation/navigation untested |
| Exact Terminal-tab navigation | Not ported | Unavailable |
| Desktop chat reading, live reply bubbles and mini-chat | Not ported | Unavailable |
| Pip installer or executable packaging | Not provided in this source workflow | Not provided |

Exact VS Code links depend on the separately installed helper publishing a fresh
local window lease. Use `yarn session-links:install`; `yarn start` alone does not
install an extension or guess among ambiguous windows. Without a supported route
the header remains plain text. Standalone Terminal-tab navigation remains
unavailable in this source app.

Windows still needs hands-on verification for native window focus, text input,
dragging, hover/click-through, display scaling, multiple monitors, file pickers,
process cancellation, filesystem ACL inheritance and reparse points, and real
Claude/Codex host hooks. These are acceptance tasks, not completed test claims.

## Demo and checks

With Pip Source running, use another terminal in this folder:

```sh
yarn demo
```

The demo publishes a synthetic request. Its displayed command never runs. To
demonstrate a real integration, trigger an ordinary supported permission request
in an already-connected agent under its existing permission settings.

Developer checks:

```sh
yarn test
yarn smoke
```

Tests cover the hook protocol, request correlation and retirement, changed or
expired requests, stale decisions, locking, structured answers, configuration
backup/restore, display helpers, appearance and animation logic. The Electron
smoke uses a hidden window and disposable runtime, with synthetic events. It
does not contact a model or change real assistant settings. Generated screenshots
go under `artifacts/`. A passing Mac smoke test is not a Windows verification.

## Update a source installation

Finish active agent work, then quit Pip Source. From
`cross-platform/` in your checkout, update the app and its optional
session-link helper before restarting. Omit the helper line if you do not use it:

```sh
git pull --ff-only
yarn install --frozen-lockfile
yarn session-links:install
yarn start
```

Resolve local Git changes through the usual review workflow; do not discard
them to update Pip.

Use **Agent connections…** again when the checkout location, hook commands or
connection configuration changes. Review changed Codex hook definitions and
reload/restart Claude after active work. Pulling source does not update the
separately installed native Swift app.

After updating the helper, reload the intended VS Code windows and run **Pip:
Refresh Session Links**. Start new agent processes after that refresh so they
inherit the window identity. Use the same Insiders/profile options as when you
first installed it.

## Restore or remove Pip Source

Finish active agent work first. Use **Restore previous agent settings…** from the
tray menu, or run this from the source folder before moving/deleting it:

```sh
yarn build
yarn connect:restore
```

Restoration refuses to overwrite settings changed since connection or a modified
backup. Review those changes rather than deleting agent settings. After a
successful restore, review/reload the agents, quit Pip Source, and remove the
checkout if you no longer need it. An existing native Mac installation can then
use its restored connection.

Local runtime locations:

- macOS: `~/Library/Application Support/PipSource/runtime`
- Windows: `%APPDATA%\PipSource\runtime`

The native app uses a separate `AgentCompanion` runtime. Never point the two apps
at the same mailbox or transfer lock/heartbeat files between them. Local settings
backups live beside the assistant settings they protect.

## Local architecture

Agent hooks send event JSON through stdin to the compiled TypeScript hook runner.
It records a correlated request in a local mailbox. The isolated renderer shows
the card and sends a narrow IPC action to Electron’s main process. The runner
returns a supported hook response to the originating agent, which applies its
own permission rules and executes the action. Pip never executes the command
shown in an approval card.

Lifecycle events and Claude’s filtered permission-decision metadata retire only
matching requests. Missing companions, invalid or changed requests, timeouts and
cancellation produce no approval. Pip’s bridge does not call a model; the agents
retain their own service, sign-in and network requirements.

The renderer has Node integration disabled, context isolation and sandboxing
enabled, a restrictive CSP, blocked navigation/new windows and validated IPC.
The local Claude receiver authenticates loopback requests and filters decision
metadata. Existing telemetry destinations are not silently replaced. Private
filesystem checks are exercised on macOS, and the helper's Windows private-file
operations are exercised in CI. Enterprise ACL variations and live desktop
integration still require native acceptance.

Relevant official references:

- [Electron prerequisites](https://www.electronjs.org/docs/latest/tutorial/tutorial-prerequisites)
- [Electron security guidance](https://www.electronjs.org/docs/latest/tutorial/security)
- [VS Code extension CLI and profiles](https://code.visualstudio.com/docs/configure/command-line)
- [VS Code manual VSIX installation](https://code.visualstudio.com/docs/configure/extensions/extension-marketplace#_install-from-a-vsix)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Claude Code decision events](https://code.claude.com/docs/en/monitoring-usage#tool-decision-event)
- [Codex hook review and trust](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks)

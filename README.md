# Pip — AI Companion for macOS

For development setup, code layout, validation and pull requests, see
[CONTRIBUTING.md](CONTRIBUTING.md). The private-beta verification record is in
[RELEASE_CHECKS.md](RELEASE_CHECKS.md).

A local macOS companion: an original blue Pip robot floats directly on the desktop, with a small rounded line just beneath its feet. Hover over the line to reveal **Claude**, **ChatGPT** and **Mini Chat**. Move away to collapse them back to the line. Claude and ChatGPT open their corresponding installed desktop apps; if an app is unavailable, Pip opens mini-chat with that provider selected. **Mini Chat** opens Pip's own chat directly, with a **Claude Code** or **Codex CLI** provider picker. Drag the robot to move it. When an AI agent needs permission, Pip shows the requesting agent and action with **Yes, allow once** and **No, reject** buttons. Claude's structured questions have answer forms.

Pip follows the macOS light or dark appearance automatically. The rounded handle uses a pale system control color in light mode and system gray in dark mode, with a subtle border. The handle, controls, permission cards, question forms, and mini-chat update when the appearance changes.

The pet is a native Swift/AppKit app. A Python bridge receives supported agent hook events and exchanges request and response files with the app in a private local directory. Claude's permission decisions also reach an authenticated receiver bound only to `127.0.0.1`. Pip keeps only the call identifiers, decision, and timing needed to remove the matching card; it does not retain the telemetry payload. There is no cloud service or new API key. The companion never executes the command being reviewed; it returns a decision to the originating agent, which remains responsible for execution and its permission rules.

Pip 0.7.2 bundles the original blue robot and twelve additional
AI-generated characters. Alongside Sunny, Mochi, Boba, Lumi, Mallow and Sprout,
Appearance now offers **Peach Puff**, **Lavender Mochi**, **Mint Bean**, **Nimbo**,
**Chai** and **Plumo** in both apps. Choose them without downloading images or
opening a file picker. The six new fluffy characters blink slowly, type at a
laptop during agent work and use an attentive waiting animation. Their frames
share a fixed center, scale and baseline. The original six retain their registered
eye blinks and attention badge. The installed app
icon keeps the original Pip artwork. See [ASSETS.md](ASSETS.md) for provenance and
rendering details.

Pip is a private macOS beta. Version **0.7.2 / build 46** adds request handoff
after successful session-header navigation. It retains the six fluffy
characters above, with thirteen gallery choices including **Default Pip**, state
previews, a saved selection and **Reset to default**. Click anywhere in a gallery
tile to select it, including its artwork and name. The native Mac app also adds
the direct **Mini Chat** hover button. It bundles the optional
**Pip Session Links 0.3.0** VS Code helper. It retains Claude's saved automatic
and custom session titles, Claude/Codex subject validation, clickable source
links, the hand cursor on headers and enabled approval buttons, approval reasons
shown once near the top, and the Claude **Other** input fix, plus the
self-contained Mac download, Pip → Applications installer window, and first-launch
agent connection setup. Automated bridge checks and synthetic requests
verify local behavior. Live model calls depend on installed agents, sign-in, and
host hook support; automated checks do not send model requests.

## Build a local Mac installer

Clone the repository, then build and open a DMG with one command:

```sh
git clone https://github.com/manishmalik23/ai-companion.git
cd ai-companion
./build-installer.sh
```

First-time setup requires macOS 13+, an installed Python 3.11+ with its full licence
file, Xcode Command Line Tools, Node 20+ and Yarn 1.22.22. The command checks these
tools and prints setup guidance for missing requirements; it does not install
global tools. Dependency setup needs approved npm and PyPI access.

This workflow uses your installed Python, a project-local virtual environment,
locked Python dependencies and the Yarn-built VS Code helper. It does not use
the portable-Python GitHub release bootstrap. The DMG targets your Mac's
architecture; its recorded minimum macOS version can be higher than the official
download's because it includes your local Python runtime.

When the DMG opens, drag **Pip** to **Applications**, then open **Pip** there.
Building and opening the DMG does not install the app or change agent hooks.
Use `./build-installer.sh --no-open` to build without opening it. See
[DISTRIBUTION.md](DISTRIBUTION.md#build-a-local-mac-installer) for this local build
workflow; the portable maintainer release workflow remains separate.

## TypeScript source for macOS and Windows

The separate [Pip Source alpha](cross-platform/README.md) implements the companion
UI and core approval workflows in TypeScript and Electron, including all twelve
additional characters, Claude question forms and the pending-request queue.
Developers can clone this repository and run it with Node.js 24 and Yarn 1.22.22.
It does not require Python or Xcode, and this workflow does not build or publish a
Pip Windows installer or executable.

Source version **0.7.2-alpha.3** adds the same session-header handoff behavior.
It retains thirteen character choices and bounded recovery from transient
Windows mailbox rename locks. It also includes
the optional **Pip Session Links 0.3.0** helper for local native Windows and macOS
VS Code windows. From
`cross-platform/`, run `yarn session-links:install` to build and install
the private VSIX, then reload VS Code after active work and run **Pip: Refresh
Session Links**. The helper appears in Extensions, not Chat Agents; `yarn start`
alone does not install it. Profiles, Insiders and manual VSIX setup are covered
in the [source guide](cross-platform/README.md#install-pip-session-links-in-vs-code).

**Windows desktop interaction and live chat navigation still need manual acceptance.**
Windows CI exercises the helper's private-file handling and component tests;
this does not establish the complete desktop experience. Desktop chat reading and the native
mini-chat fallback remain unavailable in this alpha. The guide lists the remaining platform checks and the
source update steps. Electron still supplies a platform executable at runtime,
so source execution remains subject to your organization's software policy.
The native Mac DMG below remains the recommended Mac installation.

## Install a prebuilt Mac download

Download **[Pip 0.7.2 beta 2 for Apple silicon (.dmg)](https://github.com/manishmalik23/ai-companion/releases/download/pip-v0.7.2-beta.2/Pip-0.7.2-macos-arm64.dmg)**.
The private [release page](https://github.com/manishmalik23/ai-companion/releases/tag/pip-v0.7.2-beta.2)
also contains the optional VS Code helper, readme and manifest.
You need repository access to view or download private release assets.

The app download is a DMG. Developers should [clone the repository](#build-and-install-from-source-developers)
for source; app ZIPs and packaged source ZIPs are local maintainer artifacts and
are not uploaded as release assets.
GitHub separately generates **Source code (zip)** and **Source code (tar.gz)**
links to repository snapshots; those are separate from the files we upload and
are not the app installer.

The download includes all twelve gallery companions and the original Pip robot.

Open the release DMG and drag **Pip.app** onto **Applications**. Then open
**Applications** and double-click **Pip** to start it. Copying installs Pip but
does not launch it; **Pip Preview** is an older development app. Choose
**Agent connections…**, connect Claude Code or Codex, and review the settings
change. Customers do not need Python, Xcode, Git, Node, Yarn, or a source checkout.
Their chosen agent must already be installed and signed in. Codex hook trust and
Claude reload/restart still apply. Accessibility is optional for desktop chat
reading; approval hooks do not need it.

If Pip shows no Codex approval card, open `/hooks` in Codex and inspect Pip's
definitions. After moving from the source installer to this bundled app, Codex
can mark the changed definitions **modified** and skip them until you review
and trust the new commands pointing at `Pip.app/.../PipHelper`. Connecting in Pip
does not grant that trust. Keep Pip running, then try an action that actually
requires approval in the same local host. See the
[official hook trust instructions](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

The initial local package is an Apple silicon private beta with an ad-hoc
signature, without notarization. Check its release manifest for minimum macOS and
architecture. Developer ID signing/notarization remains a separate public-release
step. See [DISTRIBUTION.md](DISTRIBUTION.md) for installation,
updates, disconnection, and reproducible maintainer builds.

## Session headers and navigation

Pip 0.6.1 includes the session-link helper. Its automated checks passed, and a
fresh window-bound connection was observed after reloading VS Code and refreshing
links. Apple Terminal tab navigation and the actual hand cursor on a Codex header
were confirmed locally by the user. Returning to the exact originating VS Code
chat remains a live acceptance step; see [RELEASE_CHECKS.md](RELEASE_CHECKS.md).

Permission and question cards show the subject at the top, with provider, host
and workspace underneath. Codex subjects come from the latest bounded 256 KiB
of its title-only local index, or a read-only stored name lookup. Claude names come from an explicit hook label,
the exact session's custom-title sidecar, or saved `custom-title` / `ai-title`
metadata records. For those records, Pip checks only the first and last 64 KiB
of the exact session file. It decodes bounded title records with a matching UUID
and skips chat messages, tool records and summaries. A title outside those two
windows may remain unavailable. Workspace-only names, UUIDs and prefixed technical
IDs are rejected as subjects. A valid explicit host title takes priority, followed
by fresh saved metadata and a valid cached subject. When no saved subject is available, Pip labels the supplied
action description **Task:**, or uses a friendly action/provider label. Commands,
prompts and transcript bodies are never used to invent a title.

Long subjects truncate on one line. The full subject and session ID remain in
the tooltip and accessibility details; the UUID is not drawn in the header.
Right-click and choose **Copy session ID** when needed. Clickable headers show an
arrow, and the mouse pointer becomes a hand on hover. This was verified on a real
Codex waiting-question card while VS Code remained active.

Clicking the header requests navigation to the identified source. After navigation
succeeds, Pip hands off only that clicked card: a new permission request returns
to the host without an allow or deny decision, so its normal approval flow can
resume. A Claude structured question uses its existing defer path; a Codex
question notice is only dismissed in Pip, and its answer stays in the original
host. Other queued requests remain answerable. Pip collapses to the character
only when no other cards remain.

Failed navigation keeps the card available and shows an error. Older permission
cards without handoff support also remain in Pip with an explanation. Local
fixtures cover this behavior. In a local Mac build 46 test, the user confirmed
that the card closed after clicking its title and the request could be approved
in Codex. Other hosts and native Windows still need live acceptance. The following
routes describe the native Mac app. TypeScript/Windows session-link scope is
documented in the [source guide](cross-platform/README.md#install-pip-session-links-in-vs-code).
Available routes depend on the host and its current identity:

- **Claude Code in local VS Code or VS Code Insiders:** uses Claude's
  [documented session link](https://code.claude.com/docs/en/vs-code#launch-a-vs-code-tab-from-other-tools)
  with a matching window link from the Pip Session Links helper.
- **Codex in local VS Code or VS Code Insiders:** Pip Session Links opens the exact
  local thread in the correct window's Codex sidebar. The compatibility adapter
  currently supports extension **26.1021.22027** only. Its installed URI route is
  not a documented public interface, so other versions stay disabled until
  verified. The helper rechecks the version and window before opening.
- **Claude Code or Codex CLI in an existing VS Code integrated terminal:** the
  helper selects a matching existing terminal process. This is terminal
  navigation, not navigation to a Codex extension chat.
- **Codex desktop local chats:** uses the documented `codex://threads/<thread-id>`
  [local-chat route](https://learn.chatgpt.com/docs/app/commands).
- **Apple Terminal:** selects an existing tab only when the captured origin
  process, process start time, and TTY still match. Its first use may ask you to
  allow Pip to control Terminal in macOS **Automation** settings. That permission
  is separate from Accessibility for the optional desktop chat reader.

For VS Code navigation, choose **Connect VS Code session links…** from Pip's
menu and review installation of **Pip Session Links**
(`pip-local.pip-session-links`). The Mac 0.7.2 app bundles helper 0.3.0; install
it into the existing VS Code application and the profile that runs the agent.
After active work finishes, run **Developer:
Reload Window**, then **Pip: Refresh Session Links** from the Command Palette
(**⌘⇧P**) in each local VS Code window. Existing agents or terminals may need to
restart after their current work finishes to inherit the new window identity.
If refresh reports unavailable, that window is not connected yet. See the
[helper README](vscode-session-links/README.md) for setup and diagnostics.

Pip's menu installer currently targets standard VS Code. For **VS Code Insiders**,
choose **Show Package Contents** on your installed Pip.app in Finder, then locate
`Contents/Resources/PipSessionLinks.vsix`. Copy that file to Downloads. In
Insiders, run **Extensions: Install from VSIX…**, select the copy, and
reload/refresh there. For a different VS Code
profile, install the helper into the profile that runs the agent.

If several windows have the same workspace open, Pip needs the originating
window key to distinguish them. An older Codex background runtime may not inherit
that key merely by reopening a chat; it must start after the helper is active.
Until a fresh runtime carries the key, Pip leaves an ambiguous link unavailable.

The helper shares only local window/workspace/terminal identifiers and its
supported Codex version. It does not read chats or project file contents, send
messages, or run agent commands. The Python bridge reads only the title metadata
described above and caches the resulting label in Pip's private session state.
Missing, closed, ambiguous, unknown, remote/SSH/dev-container, daemon, iTerm2,
and unsupported Codex extension versions remain unavailable. Pip does not guess another window,
create a terminal, or run a CLI resume command or a new agent task. A failed link
leaves the request available in Pip; copying its ID remains available.

## What the VS Code extension does

**Pip Session Links** is our small TypeScript extension, bundled as a private VSIX
inside Pip. It is separate from the Claude Code and Codex extensions, which users
install and sign in to themselves. It is not published on the VS Code Marketplace.

The integration has two paths:

- **Approvals and questions:** the assistant runs a supported hook; Pip's bundled
  Python bridge writes a correlated request into its private local mailbox; the
  Swift app shows it and returns a supported decision to the same assistant.
  Claude question forms can be answered in Pip. Codex questions are alerts: answer
  them in Codex.
- **Return to the source:** the TypeScript helper publishes an expiring record of
  its VS Code window, workspace folders and existing terminal process IDs. Pip
  validates that record and the request's identity when the header is clicked,
  then opens the matching chat route or selects the existing terminal. After
  success, Pip hands off only the clicked request without answering or approving
  it. The helper
  supplies navigation; provider hooks supply approval events.

The helper uses VS Code's extension APIs and validated local links. It does not
read chat or project file contents, send messages, approve actions, create a
terminal, or execute agent commands. Only window/workspace/terminal metadata stays
in Pip's private local files; the Python bridge separately reads the exact title
metadata described above.

For a developer demo: **“Hooks tell Pip which agent needs attention. The local
VS Code helper tells Pip where to take me when I click that request.”**

### Why does a Codex approval appear in Pip but not VS Code?

Pip's current Codex connection uses a synchronous `PermissionRequest` hook.
Codex waits for that hook before its normal approval flow. An allow or deny in
Pip resolves the request there; if no hook decides, Codex continues to its normal
approval prompt. This flow does not provide two simultaneous actionable prompts.
Making the hook asynchronous would remove its ability to approve or deny the
request. See the official [Codex permission-hook behavior](https://learn.chatgpt.com/docs/hooks#permissionrequest)
and [background-hook limits](https://learn.chatgpt.com/docs/hooks#run-hooks-in-the-background).

In build 46 and Pip Source 0.7.2-alpha.3, successful session-header navigation
returns a new permission request to that normal host flow without an allow or
deny decision. This transfers the clicked request; it does not create two active
approval prompts. Failed navigation or an older request without handoff support
keeps the card in Pip. Live Codex fallback behavior remains an acceptance check.

## Build and install from source (developers)

For a self-contained local DMG, use [the one-command installer build](#build-a-local-mac-installer)
above. The manual development/source-install flow below is also available.

Requires macOS 13 or later, Python 3.11 or later, Xcode Command Line Tools,
and installed/signed-in Claude Code or Codex for the corresponding connection.
Install Command Line Tools with `xcode-select --install` if needed.

The original Pip sprite sheet is included in this repository. No OpenAI mascot artwork is included in this repository or its app build.

Clone the repository:

```sh
git clone https://github.com/manishmalik23/ai-companion.git
cd ai-companion
./build.sh
```

The native source app can build without the optional VS Code helper package.
To include session links, maintainers need Node 20+ and Yarn 1.22.22 and must build
the private VSIX before rebuilding Pip:

```sh
cd vscode-session-links
yarn install --frozen-lockfile
yarn build
yarn test
yarn package
cd ..
./build.sh
```

The VSIX is bundled when its build artifact exists. A source build made without
that artifact may omit it. Self-contained release packaging requires the helper
package; see [DISTRIBUTION.md](DISTRIBUTION.md). Customers installing a prebuilt
download do not need Node or Yarn.

Prepare the installation plan:

```sh
python3 install_local.py --prepare
```

Review `.install-plan.json`, then apply that exact plan:

```sh
python3 install_local.py --apply
```

Installation copies the app to `~/Applications/Pip.app` and its scripts and private mailbox to `~/Library/Application Support/AgentCompanion`. It appends hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`, preserving existing settings and hooks and backing up existing files. It configures Claude's decision events for Pip's local receiver, with a one-second export interval; metrics, traces, prompt content, assistant responses, tool details, and raw API bodies stay disabled. It refuses an existing telemetry destination or headers setup rather than replacing it. It refuses changed sources/settings between preparation and application. It does not change sandbox, approval mode, or hook trust.

Open Pip from Applications. Claude settings normally reload in running sessions; confirm the entries in `/hooks`. For Codex, open `/hooks` and review and trust the new definitions, then start or resume a local session. See [Claude settings reload](https://code.claude.com/docs/en/settings#when-edits-take-effect) and [Codex hook trust](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

The new Claude decision connection loads when Claude's runtime starts. After your current action finishes, use **Developer: Reload Window** in VS Code, then continue your Claude conversation. Reloading while a step is running can interrupt it; conversations can be restored or resumed afterward. [Continue conversations after a reload](https://code.claude.com/docs/en/vs-code#continue-conversations-after-a-reload).

**Work Cloud does not run local command hooks**, including when it has local computer access. These connections require fully local orchestration and execution. Ordinary ChatGPT browser sessions and arbitrary editor extensions do not attach through this installer. [Work Cloud compatibility](https://learn.chatgpt.com/docs/enterprise/cloud-local-access#check-hooks-and-network-compatibility).

## Update an existing installation

For prebuilt downloads, finish current actions, quit Pip, replace the app in the
same Applications folder, then open it. Existing data remains outside the app.
If moving from a source install to a prebuilt download, open **Agent connections…**
and reconnect the agents so their hook paths point at the bundled helper. Review
changed Codex hooks and reload/restart Claude after its current action finishes.
See [DISTRIBUTION.md](DISTRIBUTION.md) for the full update/disconnect flow.

If you use VS Code session links, updating Pip also updates the VSIX bundled
inside the app. Install/update it through **Connect VS Code session links…**,
finish active assistant work, run **Developer: Reload Window**, then run **Pip:
Refresh Session Links** in each window. Replacing Pip.app alone does not reload
an extension already running in VS Code.
For Insiders, use the manual bundled-VSIX installation described above.

For source installs, there is no automatic updater. Pulling the repository updates
the source; rebuild and reinstall to update `~/Applications/Pip.app`.
Finish any active assistant action and resolve pending approvals, then choose
**Quit Pip** before replacing the app.

From the repository root, with a clean working tree:

```sh
git switch master
git pull --ff-only
./build.sh
python3 install_local.py --prepare
```

Review the new `.install-plan.json`, then apply it and reopen Pip:

```sh
python3 install_local.py --apply
open ~/Applications/Pip.app
```

The installer preserves custom character profiles and unrelated assistant settings
and checks that the installed app and managed files have not been modified.
It restores the installed runtime path in the new bundle so Pip and its hooks use
the same mailbox. If preparation reports modified managed files, stop and review
those changes rather than deleting the app or overwriting them.

For an app-only update with identical hook definitions, another hook review is
normally unnecessary. If hook commands change, review them in the host's `/hooks`
menu; reload VS Code or restart/resume Claude Code after its current action
finishes when needed. Refresh Accessibility only if you want desktop chat reading
and macOS no longer recognizes Pip's ad-hoc signature. Approval hooks work without
Accessibility.

## Choose your character

Open **Appearance…** from Pip's menu-bar menu (or press **Command+,** while Pip is
active). Select a gallery character, review its preview, then choose **Use
character**. You can switch again at any time. **Default Pip** and **Reset to
default** return to the original blue robot.

| Character | Look |
| --- | --- |
| Sunny | Yellow robot with large brown eyes |
| Mochi | Mint-and-ivory robot with small ear fins |
| Boba | Lilac robot with amber eyes |
| Lumi | Peach creature with coral glasses and mint dungarees |
| Mallow | Pink creature in a turquoise knitted hoodie |
| Sprout | Aqua creature in a mustard hoodie |
| Peach Puff | Peach fluff, big eyes and a tiny antenna |
| Lavender Mochi | Lavender fluff, floppy ears and a playful tuft |
| Mint Bean | Mint-green bean shape and a cheerful face |
| Nimbo | A small sky-blue cloud cushion |
| Chai | A cinnamon oval puff with a cream curl |
| Plumo | A berry-purple rounded lozenge |

All twelve are bundled for offline use in Pip 0.7.2. Click anywhere in a tile,
including the artwork or name, to select it. Appearance scrolls to
show all thirteen choices including Default Pip. Preview **Idle**, **Working**
or **Waiting**, then apply your choice. The new six use their own four-column,
three-row sheets with slow blinks, laptop typing and attentive waiting. Shared
frame bounds keep their center and baseline anchored without adding robot eye
or sparkle overlays. The earlier six retain their stationary laptop poses,
registered eye patches and waiting badge.

Custom artwork remains available: choose **Still image** or **Animated sheet**,
then **Choose character…** to import a PNG or WebP. Previewing leaves the current
desktop character in place until **Use character** is selected. Images are
limited to 10 MB and 4096 pixels per side; a transparent background looks best.
Still images keep their proportions and do not animate. Animated imports support
Pip's 1254 × 1254 sheet (four columns; idle, working, waiting rows), plus the legacy
nine-row layout on a transparent 1536 × 1872 or 1536 × 2288 canvas.

The choice is saved in Pip's private `appearance/character.json` outside the app
bundle and survives restarts and app updates. Built-in choices save their catalog
identifier in a version 2 profile; imported images retain a private copy, and
existing version 1 custom profiles remain supported. Changing artwork needs no
new Accessibility grant or rebuild. The original imported image is never changed
or removed. Finder's installed app icon remains the bundled Pip icon.

See [RELEASE_CHECKS.md](RELEASE_CHECKS.md) for the exact gallery, persistence,
rendering and manual verification completed for this build. The native custom
file picker remains a separate manual check.

## Mini-chat

**Pip 0.3.16:** Codex and VS Code agent activity no longer creates a conversation bubble. The global Codex hook activity feed is disabled, including its old saved preference; the menu no longer offers that feed. Supported approval cards and the robot working animation remain independent. Pip mini-chat and the verified Claude desktop reader retain conversational Thinking. Only a complete short answer with no internal line breaks that fits one visible line appears above Pip for six seconds. Multi-line or wrapping replies remain in their chat window. Ordinary ChatGPT desktop Chat is not connected; Pip does not substitute Codex activity for it.

The installed app was normally restarted and verified through its own status as ‘Codex activity bubbles are off · ChatGPT Chat is not connected.’ The live hook capability is disabled. The app builds successfully. The native conversation suite passed 58 checks and the offscreen light/dark bubble suite passed 138 checks, including physical line separators, wrapping text, Unicode, and rejection followed by a new fitting reply.

Hover over the line beneath the robot and choose **Mini Chat** to open Pip's own
chat directly, even when the desktop apps are installed. This button bypasses
desktop-app discovery. **Open mini-chat** remains available in Pip's menu-bar menu.
Choose **Claude Code** or **Codex CLI** in the chat window's provider picker.
These are the installed local CLI backends, using their existing sign-in.

Mini Chat keeps its own conversation and workspace for each provider. It does not
import or synchronize conversations from a desktop app, VS Code or another CLI
session. Reopening the window retains its own conversation while Pip is running;
**New conversation** resets the selected provider's conversation and workspace.
Restarting Pip begins fresh. Opening the window or changing providers sends no
message until you choose **Send**.

The neighboring **Claude** and **ChatGPT** buttons still open their corresponding
installed desktop apps without submitting a message. If an app is missing or
cannot open, Pip opens mini-chat; the ChatGPT fallback uses **Codex CLI**.

In mini-chat, **Enter** sends, **Shift+Enter** adds a new line, and **Command+Enter** also sends. A rounded capsule above the robot shows the conversation title, a circular app badge, and slow thinking dots while a real Pip chat turn runs. A complete short reply that fits one visible line appears in a speech bubble for six seconds; multi-line or wrapping replies stay in the chat window and the bubble disappears. Permission cards take priority. The capsule follows the system appearance, stays within the screen, and respects Reduce Motion.

Desktop chat connection is enabled by default in Pip 0.3.23. This update enables it once; if you turn it off afterward, that choice persists. Startup never opens an Accessibility setup dialog. If permission is unavailable, the connection remains enabled and waits quietly; granting access lets it connect automatically. To set it up explicitly, choose **Connect desktop chats** in Pip's menu when the connection is off, or **Accessibility settings…**, then enable **Pip** under **System Settings → Privacy & Security → Accessibility**. Only the explicit connection action opens Pip's setup dialog. Claude Code and Codex approval hooks do not require Accessibility.

Choose **Claude** beneath Pip to select the verified desktop reader. **ChatGPT** opens its desktop app, but ordinary ChatGPT Chat is not connected and Codex activity bubbles are disabled. The connection uses Apple's public Accessibility interface to read the selected app's visible chat title, explicit response/activity controls, and assistant messages. Opening a conversation baselines its existing reply; Pip shows only a new settled response. The menu and robot's hover text report whether the selected app is connected, needs permission, or does not expose readable chat content. The same status is available to accessibility tools. Failed reads include a brief reason without chat content. Turn the connection off from the same menu. [Apple Accessibility permission](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).

Desktop reading is experimental and depends on the installed app exposing identifiable conversation and assistant-message elements. A reply requires a stable conversation identity, an observed Stop/activity control, and two settled samples after it disappears. Fast responses that finish between polls may remain only in the desktop app. Unavailable content or a missing window does not count as a completed answer. The reader selects the latest classified assistant response, discards incomplete content, and treats failed generation-control reads as unavailable rather than completion. Reads use a fixed time and node budget; diagnostics contain only static error categories and counters. Editable message input, user-message bodies, sidebars/history lists, login dialogs, and other applications are excluded. Minimal accessibility labels classify message roles; chat content is never persisted, and the observer does not send messages.

Window discovery can fall back to exactly one eligible standard window when focused/main references are absent. Claude's exact local app page can wrap a verified official conversation; the reader follows only that selected route through the wrapper. Repeated ancestors, ambiguous windows, unrelated pages, and incomplete reads remain unavailable. Synthetic checks validate these layouts, the response lifecycle, overlapping Pip/desktop turns, and failure handling. On October 12, 2026, installed Pip 0.3.13 received its restored Accessibility permission and connected to Claude's visible “Hello from Claude” chat. The approved neutral test exposed Claude's “Stop response” control, returned “Hello from Claude,” and produced Pip's “New short Claude reply received” status. This verifies the live selected title and generation-to-completion reader path; the desktop tool's screenshot captured only the robot window, so the separate Thinking/reply bubble was not visually verified. Ordinary ChatGPT desktop Chat is unavailable in this beta; do not expect titles or replies from it.

The installer seals the final Pip bundle before installation. This local build uses an ad-hoc signature, so macOS may require Accessibility approval again after a later update changes its executable. If Pip still reports waiting while its switch is on, remove only Pip from the Accessibility list and add the installed `~/Applications/Pip.app` again. System Settings may require Touch ID or your Mac password before allowing the change. No signing certificates or Keychain entries are created. [Apple code-signing identity](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Each provider keeps its own draft and conversation owned by Pip; later messages resume only that conversation. Every new conversation starts in a separate private workspace outside your repositories, so a greeting does not automatically load a work project's instructions and saved context. User-level CLI customization and sign-in still apply. **New conversation** clears that provider's draft, title, and session and allocates a fresh workspace. Finish or stop an active reply before switching providers. Existing chats in other apps remain independent.

Mini-chat invokes your installed CLI with its existing sign-in; it does not request a new API key. Codex chat starts with a read-only sandbox and requests approval when needed. Claude uses its normal manual permission mode. Permission and question hooks must be available and trusted for tools requiring interaction; noninteractive fallback may reject a tool instead of showing a prompt. Stop cancels the active child process.

The prebuilt Mac app discovers CLIs through its available PATH and common local
installation locations, including Codex bundled with the VS Code extension.
The developer/source installer can record explicit CLI paths; if one of those
paths moves, regenerate and apply its installation plan.

## Validate and package the private beta

Run the checks from a cloned checkout:

```sh
./scripts/check.sh
```

Maintainers can optionally create a local source snapshot with verified hashes:

```sh
python3 scripts/package_beta.py
```

The checks do not send real model messages. The clean-install check installs the built app into a temporary home, verifies its signature and hook configuration, then checks an update preserves the custom profile and settings; it does not launch that app or change your real settings. The optional source snapshot excludes runtime data, installation plans, builds, signing credentials, and the old OpenAI robot. It remains a local maintainer artifact; developers get source by cloning the repository. The self-contained Mac builder and its internal app ZIP checks are documented in DISTRIBUTION.md. The published app download is the DMG; its private beta is ad-hoc signed without notarization.

## Run locally

Requires macOS, Python 3.11 or later, and the Swift compiler supplied by Xcode Command Line Tools.

```sh
# Run from the repository root
./run.sh
```

The launcher builds and starts the native app with this project's `.runtime` directory. Keep it running while using the hooks. From a second terminal:

```sh
./demo.sh
```

The demo sends three synthetic permission requests. Their command text is only displayed; no commands are run. Choose Yes, allow once or No, reject on the pet to exercise the response flow.

Run the automated checks with:

```sh
python3 -m unittest discover -s tests
```

The native mailbox checks run without opening a UI:

```sh
swiftc -module-cache-path .build/module-cache desktop/Models.swift desktop/RuntimeChecks.swift -o .build/runtime-checks
.build/runtime-checks
```

The desktop reader uses synthetic accessibility trees, and the bubble checks render offscreen without opening a chat or sending a model request:

```sh
swiftc -O -module-cache-path .build/module-cache desktop/Models.swift desktop/ProviderApps.swift desktop/DesktopChatObserver.swift desktop/DesktopChatObserverChecks.swift -o .build/desktop-chat-observer-checks
.build/desktop-chat-observer-checks
swiftc -O -module-cache-path .build/module-cache desktop/Models.swift desktop/ProviderApps.swift tests/ConversationStateChecks.swift -o .build/conversation-state-checks
.build/conversation-state-checks
swiftc -O -module-cache-path .build/module-cache desktop/Models.swift desktop/ProviderApps.swift desktop/RobotArt.swift desktop/CreatureCharacters.swift desktop/BubbleDesign.swift tests/BubbleDesignChecks.swift -o .build/bubble-design-checks
.build/bubble-design-checks
swiftc -O -module-cache-path .build/module-cache desktop/RobotArt.swift desktop/CreatureCharacters.swift desktop/Appearance.swift tests/AppearanceChecks.swift -o .build/appearance-checks
.build/appearance-checks
swiftc -O -module-cache-path .build/module-cache desktop/Models.swift desktop/ProviderApps.swift tests/CodexHookActivityChecks.swift -o .build/codex-hook-checks
.build/codex-hook-checks
```

Keep this repository in a permanent folder. The installer copies the app and bridges into your home directory, so the installed app does not depend on the source folder. Use `./scripts/check.sh` for all checks. Maintainers can use `python3 scripts/package_beta.py` for an optional local source snapshot; it is not a release upload.

## Connect an agent

The setup helper only prints JSON for review. It does not install hooks, edit global configuration, or enable an integration.

```sh
python3 setup_hooks.py --source claude
python3 setup_hooks.py --source codex
python3 setup_hooks.py --source chatgpt-work
```

Each command emits a separate configuration using that source label. Select the source for the agent you are configuring. `--runtime /absolute/path` can select a different IPC directory, but the hook and native app must use the same directory.

When Claude reports a decision for a precisely identified call, Pip removes its matching card while the approved action continues running. The one-second export interval can add a short delay. The decision event is linked to the call's `PreToolUse` identity; it does not supply an approval response. Tool completion and matching turn/session events remain the fallback. Other sessions and pending calls stay visible. The pet shows its laptop while an agent is working. [Claude tool decision events](https://code.claude.com/docs/en/monitoring-usage#tool-decision-event).

The printed commands include absolute Python and bridge paths, quoted for shell use. Regenerate them if you move the project or change the Python installation. Permission requests wait for a pet decision for up to 120 seconds, with a 130-second host hook timeout. Lifecycle hooks use a two-second timeout and return no decision.

Review the generated configuration, then merge it manually:

1. For Claude Code, use the existing `hooks` object in `~/.claude/settings.json`, or a project's `.claude/settings.json` / `.claude/settings.local.json`.
2. For Codex or the local Codex runtime in ChatGPT Work, use `~/.codex/hooks.json` or the project's `.codex/hooks.json`. The printed object is a hooks configuration, not a replacement for `config.toml`.
3. Preserve unrelated settings and existing event handlers. Append the generated matcher groups to each event's array; do not replace the file or overwrite existing hooks. Avoid appending the same companion hook more than once.
4. Follow the host's hook trust flow. In Codex, review and trust the exact hook definition through `/hooks`. Use the host's hook inspector to confirm it is loaded. A changed definition may need review again.
5. With the companion running, try a harmless action that your agent's current permission policy actually requires you to approve. Observe the pet and the agent together before relying on it for normal work.

The companion registers `PermissionRequest` plus `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, and `SessionEnd` to show activity and retire resolved requests. Claude also uses `PostToolUseFailure`, `PostToolBatch`, `StopFailure`, `Notification` with matcher `permission_prompt`, and `PreToolUse` for `AskUserQuestion`. A separate noninteractive `PreToolUse` tracker records only call identifiers and an input digest for decision matching. Codex also uses `Interrupt` and question-tool `PreToolUse` events. A request carries its own identifier; a response applies to exactly that pending request and does not create an always-allow rule. **Approve once** returns an allow decision, and **Deny** returns a deny decision. Existing host restrictions can still prevent an allowed action.

For a supported Claude Code question, choose an option or select **Other** to type
a custom answer in Pip. Selecting **Other** focuses the answer field and scrolls
it into view. **Submit answers** becomes available when every question has an
answer. **Answer in Claude** leaves the answers for the original app.

Claude questions show the original options and allow typed answers. **Submit answers** returns the exact question array plus the answers in the documented `updatedInput` shape. **Answer in Claude** returns no hook decision and leaves the original question flow available. [Claude interaction hooks](https://code.claude.com/docs/en/hooks#tools-that-require-user-interaction).

For local Codex, a `PreToolUse` matcher attempts to show structured `request_user_input` and `request_user_input_async` calls as alerts. Specialized and hosted tool paths can skip that hook, so question coverage must be checked in your host. These alerts are answered in the originating app; no Codex answer injection is performed. An async question's immediate acknowledgement does not dismiss its alert. Existing hooks do not report its exact answer event, so the alert clears when its turn ends or is interrupted, its session ends, it is dismissed, or its two-minute lifetime expires. It may therefore clear before a later async answer. Ordinary prose questions appear in mini-chat's transcript but have no universal notification hook.

Claude notification alerts show **Continue in Claude Code** with a dismiss button. They cannot approve or deny the underlying action; use Claude's own prompt. A notification can follow a decision only when exactly one active call is identified across the whole session and the decision occurred after the alert appeared. Parallel or unidentifiable alerts retain matching completion/turn/session events, two-minute expiry, or manual dismiss as fallback. A prior approval does not clear a later sandbox-network alert. Claude does not document a separate network-approval decision event, so instant removal is not guaranteed for those alerts. Claude permission notifications in VS Code need version 2.1.233 or later; terminal sandbox network notifications need 2.1.246 or later. See the [Claude hook lifecycle](https://code.claude.com/docs/en/hooks) and [Codex hook lifecycle](https://learn.chatgpt.com/docs/hooks) for the available signals.

If the app is unavailable or no decision arrives before the wait expires, the bridge returns no approval decision and the agent follows its native permission flow. In a noninteractive agent session, that flow may deny the action instead of opening a prompt.

## Supported scope

| Source | Intended integration | Limits |
| --- | --- | --- |
| Claude | Claude Code permission hooks in CLI and its corresponding IDE runtime | Sandbox network requests appear as notification alerts; approve or deny those in Claude's own prompt. |
| Codex | Local Codex permission hooks | Hooks must be supported and trusted in the installed host. Source labels do not grant permissions or attach to another process. |
| ChatGPT Work | Fully local Codex hooks exposed by the Work runtime | Work Cloud does not execute local command hooks. This does not collect every ChatGPT UI prompt or browser request. |
| VS Code | Corresponding Claude or Codex runtime hooks | This does not monitor arbitrary VS Code extensions or provide a universal editor approval listener. |

Hook behavior depends on the host and installed version. Claude's sandbox network exception and VS Code's separate runtime schemas are documented in the [Claude hooks reference](https://code.claude.com/docs/en/hooks#permissionrequest) and [VS Code hook configuration](https://code.visualstudio.com/docs/agent-customization/hooks). Review [Codex hooks](https://learn.chatgpt.com/docs/hooks) for its permission payload and trust requirements. The shared local runtime context is described in [OpenAI plugin concepts](https://developers.openai.com/plugins/concepts/plugins) and [plugin building](https://developers.openai.com/plugins/build/plugins).

## Local data

`.runtime` contains local activity, permission requests, and responses. Request details can include command text and paths from the agent. The bridge uses a private directory for IPC; this is a local user process boundary, not a defense against other software running as the same macOS user. Keep the project and generated hooks under your control.

To disconnect the companion, remove only its generated hook entries from the agent's configuration and close the app. No agent settings are changed by starting the app or printing setup JSON.

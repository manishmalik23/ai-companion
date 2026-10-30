# Installing and distributing Pip

## Build a local Mac installer

From a new clone:

```sh
git clone https://github.com/manishmalik23/ai-companion.git
cd ai-companion
./build-installer.sh
```

This requires macOS 13+, an existing Python 3.11+ installation with its full licence
file, Xcode Command Line Tools, Node 20+ and Yarn 1.22.22. Missing prerequisites
produce setup guidance; the command does not install global tools. Dependency
installation needs approved npm and PyPI access.

The command creates a project-local Python environment with locked packaging
dependencies, builds the private VS Code helper with Yarn, and packages Pip using
your installed Python. It does not run the portable-Python GitHub release
bootstrap used by the separate maintainer workflow below. The resulting DMG is
for your Mac's architecture. Its manifest and readme state the actual minimum
macOS version, which can be higher than the official release's because of the
local Python runtime.

The DMG opens when the build succeeds. Drag **Pip** onto **Applications**, then
open **Pip** from Applications. The build command does not install or replace an
app, launch Pip, or change agent settings/hooks. Use
`./build-installer.sh --no-open` to leave the finished DMG unopened. First-launch
agent connection review and host hook trust still apply.

Use `./build-installer.sh --check` to check prerequisites without downloading or
creating build files. `--python /path/to/python3` selects another installed
Python, and `--output /path/to/new-folder` chooses a new output directory.
Existing output paths are never overwritten. Concurrent installer builds from
the same checkout are rejected to protect the shared build outputs.

## Source-run TypeScript alpha

The [TypeScript source guide](cross-platform/README.md) covers cloning, Yarn
installation, hook connection, updates and restoring previous agent settings.
It is a separate alpha for macOS and experimental native Windows. Windows desktop
interaction and live agent navigation still need manual acceptance. This workflow does not create or publish a
Pip installer or packaged Windows executable. Electron's own runtime still
contains platform binaries and remains subject to organizational policy.

For exact local VS Code chat links, source users separately run
`yarn session-links:install` from `cross-platform/`. This builds Pip
Session Links 0.3.0 and installs the private VSIX through the existing VS Code
CLI. `yarn session-links:build` produces the archive for manual **Extensions:
Install from VSIX…** installation. The helper appears in VS Code's Extensions
view, without a Chat Agent or sidebar icon. Finish agent actions before reloading
VS Code, then run **Pip: Refresh Session Links** in each local window. See the
[source setup guide](cross-platform/README.md#install-pip-session-links-in-vs-code)
for profiles and Insiders.

This adds experimental session links for native Windows VS Code; WSL, SSH and
dev-container windows remain unsupported. Windows CI exercises the private-ACL
writer and component tests; real VS Code installation, focus and live navigation
remain manual acceptance checks.
No Pip `.exe` or Windows installer is produced. Pip Source **0.7.2-alpha.3**
adds request handoff after successful session-header navigation. It retains the
six fluffy characters and bounded recovery from transient Windows mailbox
rename locks. The native Mac 0.7.2 app below also bundles helper 0.3.0.

The Mac release instructions below apply to the native Swift/Python app.

## Install a prebuilt download

Download the **[Apple silicon DMG](https://github.com/manishmalik23/ai-companion/releases/download/pip-v0.7.2-beta.2/Pip-0.7.2-macos-arm64.dmg)**.
Download publication is a
separate release step; building this repository does not publish a release.
The private [Pip 0.7.2 beta 2 release](https://github.com/manishmalik23/ai-companion/releases/tag/pip-v0.7.2-beta.2)
provides the DMG, optional standalone Pip Session Links VSIX, readme and release
manifest. Repository access is required. Developers should [clone the repository](README.md#build-and-install-from-source-developers)
for source. App ZIPs and packaged source ZIPs are local maintainer artifacts,
not uploaded release assets.
GitHub's automatically generated **Source code (zip)** and **Source code (tar.gz)**
links are repository snapshots, separate from our uploaded files and the DMG
installer.

Version **0.7.2 / build 46** adds safe request handoff after successful session
navigation. It retains Peach Puff, Lavender Mochi, Mint Bean, Nimbo,
Chai and Plumo, with slow blinking, laptop typing and attentive waiting. The
gallery now offers twelve companions plus **Default Pip**, with state previews,
a saved selection and **Reset to default**. Gallery tiles respond across their
artwork and names, and the native Mac hover controls add a direct **Mini Chat**
button. It bundles the optional Pip Session
Links 0.3.0 helper and retains Claude automatic-title metadata lookup,
Claude/Codex subject validation, source links, hand-pointer feedback, the single
approval-reason display and the Claude **Other** text-field fix. Finish pending requests,
quit Pip, replace the existing app from the new DMG, and reopen it. Settings and
custom characters stay outside the app bundle.

Apple Terminal navigation and the actual hand cursor on a Codex header were
confirmed locally by the user. The helper's current window-bound connection and
automated routes passed checks; exact-chat navigation in VS Code remains a live
acceptance step. See [RELEASE_CHECKS.md](RELEASE_CHECKS.md).

1. Open the DMG. Its installer window shows **Pip → Applications**; drag the Pip
   icon onto Applications.
2. In Finder, open **Applications**, then double-click **Pip**. Dragging/copying
   installs the app but does not start it. You can close/eject the disk image;
   the installed app remains in Applications. **Pip Preview** is the older
   development app and is not included in this download.
   The first launch shows **Agent connections…**, also available from
   Pip's menu-bar icon.
3. Connect Claude Code or Codex. Review the named settings file and click
   **Connect**. Existing settings/hooks are preserved and changed files are backed up.
4. In Codex, review and trust the definitions in `/hooks`. Reload/restart Claude
   Code after its current action finishes, so its local decision connection loads.

Codex can show **modified** for Pip after the hook command/path changes. Those
hooks are skipped until their current definitions are reviewed and trusted.
Pip's Connected status means its settings were installed; it does not mean Codex
has granted hook trust. No Pip installer bypasses or grants that approval.

If you double-click Pip while it is still in the DMG or Downloads, it offers
**Move to Applications**. This copies/verifies the app, opens the installed copy,
and shows Agent connections. If your Mac does not allow writing to the system
Applications folder, the button uses your own `~/Applications` folder. Replacing
an existing Pip requires confirmation and moves the previous app to Trash. Quit
any other Pip instance before replacing it. No agent connections change until
you review and choose Connect. Manual drag-and-drop remains available.

Customers do **not** need Python, Xcode, Git, Node, Yarn, a source checkout, or a
terminal install command to run this package. They do need their chosen agent
installed and signed in. Pip detects common CLI locations and VS Code extensions;
it does not install an AI agent, bypass its login, or change its permission mode.
Accessibility is only needed for the optional experimental Claude desktop reader,
not approval hooks. Ordinary ChatGPT desktop Chat reading remains unavailable.

The release manifest and Read me state the actual minimum macOS version and CPU
architecture. Build/runtime dependencies can require a newer macOS than the Swift
source itself. Do not advertise an Intel or older-macOS build until it is built and
tested for that target. The initial local release artifact is Apple silicon.

The private beta uses an ad-hoc signature and is **not notarized**. macOS may show
a security warning requiring manual approval. A Developer ID signed, notarized
download is a separate public-release step and needs the publisher's membership.

## Change the character

Open Pip's menu-bar menu → **Appearance…**, select a built-in character or
**Default Pip**, then choose **Use character**. Pip 0.7.2 offers
twelve companions plus the default, with scrolling and Idle, Working and Waiting
previews. Previewing leaves the selected character unchanged until you apply it.
Click anywhere in a tile to select it, then choose **Use character** to save it.
The gallery requires
no image download or file picker. **Reset to default** restores the original
blue robot. Peach Puff, Lavender Mochi, Mint Bean, Nimbo, Chai and Plumo use
anchored animation frames for slow blinking, laptop typing and waiting. The
earlier six keep their stationary laptop pose, eye blinks and attention badge.

The selection is stored privately outside Pip.app, so replacing the app preserves
it. A version 2 profile records the built-in catalog identifier; existing version
1 imported-image profiles remain supported. Users can still import a custom PNG,
WebP or compatible animation sheet from the same Appearance window. The app
bundles its artwork, so character selection does not require a network connection,
new Accessibility permission, an agent hook change, or a rebuild.

## Mini Chat on Mac

Hover over the line beneath Pip and choose **Mini Chat** to open its own chat
directly. Select **Claude Code** or **Codex CLI**, type a message, then press
**Enter**, **Command+Enter** or **Send**. **Shift+Enter** adds a new line. The
chosen CLI must already be installed and signed in; Pip uses that existing
connection without asking for a new API key.

Each provider has its own Mini Chat conversation and private workspace. It does
not import or synchronize desktop, VS Code or other CLI chats. **New conversation**
resets the selected provider's conversation. Reopening the window retains it
while Pip runs; restarting Pip begins fresh. The **Claude** and **ChatGPT** hover
buttons continue to open the installed desktop apps. The direct Mini Chat entry
is a native Mac feature; the TypeScript source alpha has no mini-chat backend.

## Session navigation

Request cards place the saved subject at the top and provider, host and
workspace beneath it. The full UUID is available in the tooltip and **Copy
session ID** context menu. When a saved subject is unavailable, an explicit
**Task:** description or friendly action/provider label is used. Codex has a
title-only local metadata lookup. Claude supports explicit hook names, its
custom-title sidecar and saved `custom-title` / `ai-title` records. Pip reads
bounded first/last 64 KiB windows of the exact session file and decodes only
complete, matching title records. Message bodies, prompts and summaries do not
become titles. A title outside those windows can remain unavailable. Codex reads
the latest bounded 256 KiB of its title-only index and can fall back to the
read-only stored `name` field. Workspace/ID-shaped labels use the labelled task
fallback rather than becoming a conversation subject.
Navigation is source-specific and does not submit an answer or approval.

After a session header successfully opens its source, both the native Mac app
and Pip Source hand off only the clicked card. A new permission request returns
no allow or deny decision, letting the host resume its normal approval flow.
Claude structured questions use their existing defer path. Codex question
notices are only dismissed in Pip; answer them in the original host. Other queued
requests stay answerable, and Pip collapses to the character only when the queue
is otherwise empty.

If navigation fails, the card remains available with an error. Older permission
cards without handoff support also remain in Pip with an explanation. Fixtures
cover the handoff logic. Local Mac build 46 acceptance confirmed that clicking
the title closed the card and allowed approval in Codex; other host/platform
combinations remain separate live checks. See
[RELEASE_CHECKS.md](RELEASE_CHECKS.md) for completed acceptance checks.

Local Claude Code VS Code chats require Pip's private **Pip Session Links**
helper to bind the documented Claude session URL to the correct window. The
same helper can select an existing integrated terminal by its process identity.
It shares local window/workspace/terminal metadata, without reading chat or
project file contents, creating terminals, or running agent commands.

Helper 0.3.0 also supports the installed Codex extension **26.1021.22027** through
a version-gated adapter. It rechecks the exact window, thread UUID and extension
version, then opens that thread in the Codex sidebar. This installed URI route is
not a public compatibility guarantee; unverified extension versions are disabled.
After updating the helper, finish active work and reload the VS Code window
before refreshing session links.

The prebuilt app bundles **Pip Session Links 0.3.0**
(`pip-local.pip-session-links`), an optional private TypeScript VS Code extension.
It requires an existing VS Code installation and the same profile as the agent. Choose
**Connect VS Code session links…**, review the installation, finish active work,
then run **Developer: Reload Window** followed by **Pip: Refresh Session Links**
in each local VS Code window. Existing agents may need a restart after their
current work finishes to inherit the window identity. An unavailable refresh
means that window has no usable navigation connection.

The menu installer currently targets standard VS Code. For **VS Code Insiders**,
use Finder's **Show Package Contents** on the installed Pip.app, locate
`Contents/Resources/PipSessionLinks.vsix`, and copy it to Downloads. Select that
copy through Insiders' **Extensions: Install from VSIX…** command, then reload
and refresh links in Insiders.
Install into the agent's profile if using a different VS Code profile.

Multiple windows with the same workspace need the captured origin window key.
An older Codex background runtime may lack it even after a chat is reopened;
the runtime must start after the helper is active. Pip leaves ambiguous matches
unavailable until a fresh runtime supplies that identity.

Codex desktop uses its documented `codex://threads/<thread-id>` local-chat route.
Apple Terminal navigation requires a matching live origin process, start time,
and TTY. The first Terminal navigation may request macOS Automation consent for
Pip to control Terminal; this is separate from the optional Accessibility grant
used for desktop chat reading. Pip does not run a CLI resume command or start a
new agent task to navigate.

Unknown, remote/SSH/dev-container, daemon, iTerm2, and unsupported Codex IDE versions are
unavailable. Closed or ambiguous source contexts also fail without selecting a
different window. Keep live-host navigation results separate from synthetic
checks; see [RELEASE_CHECKS.md](RELEASE_CHECKS.md) for the verification record.

## Build a self-contained download (maintainers only)

On a Mac with Python 3.11+, Xcode Command Line Tools, Node 20+, and Yarn 1.22.22,
run from the repository root. Build and validate the VS Code helper first:

```sh
cd vscode-session-links
yarn install --frozen-lockfile
yarn build
yarn test
yarn package
cd ..
python3 scripts/bootstrap_package.py
.build/release-python/venv/bin/python scripts/package_macos.py --dmg
```

The source helper package is `vscode-session-links/artifacts/pip-session-links-0.3.0.vsix`.
The release builder requires it and bundles it as `PipSessionLinks.vsix` in the
app's resources. The native `build.sh` can run without that artifact and may then
omit the helper. Prebuilt customers use VS Code's extension runtime and do not
need a separate Node or Yarn installation. The helper is a private VSIX; it is
not published on the VS Code Marketplace.

This compiles the Swift app, freezes the Python bridge/chat/setup entry points
into a nested helper app, includes its interpreter/libraries and licence notices,
seals the bundle, verifies its signature, and produces a ZIP and DMG with hashes.
The DMG includes an Applications shortcut. The ZIP contains only Pip.app; build
logs, source, settings, test data, and credentials are excluded. The one-folder
runtime avoids extraction on every short-lived hook invocation.

The app ZIP is retained locally for packaging and verification. An optional
source ZIP from `scripts/package_beta.py` is also a local maintainer snapshot.
Publish the DMG, private helper VSIX, readme and release manifest; do not upload
either ZIP. Developers clone the repository to build or contribute.

The bootstrap downloads the pinned Python 3.12.15 standalone build from Astral's
official GitHub release, verifies its SHA-256, and creates an isolated maintainer
environment under `.build`. It installs no system-wide Python. Full upstream
dependency licence notices accompany the shipped runtime. A portable build avoids
accidentally inheriting a new Homebrew installation's newer macOS requirement;
the packager rejects binaries requiring above macOS 13 by default.

Outputs go to `.build/releases/Pip-VERSION-macos-ARCH/`. Existing output folders
are never overwritten; use `--output /absolute/new/folder` for another candidate.
The builder uses the architecture of its Python interpreter. Build/test Intel
releases on an Intel runner or a deliberately configured Intel build environment;
the builder does not combine frozen executables with `lipo`.

Run the source checks and then the packaged-runtime checks against the full
local build folder, including its internal app ZIP and manifest:

```sh
./scripts/check.sh
.build/release-python/venv/bin/python scripts/check_packaged.py --app /absolute/path/to/Pip.app
.build/release-python/venv/bin/python scripts/check_downloads.py --release /absolute/path/to/release-folder
```

Packaged checks use a disposable home, actual generated hook commands and fake
agent output. They do not change your real hooks, launch a live model, or require
an external Python runtime in the packaged helper's execution environment.

With a Developer ID certificate and an existing notarytool Keychain profile:

```sh
.build/release-python/venv/bin/python scripts/package_macos.py --dmg \
  --identity 'Developer ID Application: YOUR NAME (TEAMID)' \
  --notary-profile PipNotary
```

This signs nested code inside out, submits/staples the app, then submits/staples
the signed DMG. Signing credentials stay in Keychain. The local private-beta
verification does not validate the Developer ID/notarization path without those
credentials.

## Configuration and updates

Pip locates its helper relative to its installed bundle. Machine-specific data
stays in `~/Library/Application Support/AgentCompanion/`; the signed bundle is
never rewritten on first launch. Existing runtime and character data stay there.

Connection setup prepares a private, expiring plan. Apply rejects changed settings
or a changed helper, backs up changed files, and rolls back a partial write.
Only Pip's exact managed hook invocations are migrated/replaced or disconnected.
Existing third-party telemetry configuration is preserved; setup stops with an
explanation when it conflicts with Pip's local Claude decision receiver.

To update a prebuilt install: finish active requests, quit Pip, replace Pip.app in
the same Applications location, and reopen it. Existing stable hook paths continue
to point at the new helper; host trust requirements still apply. Moving/renaming
an already connected app changes its hook paths: reopen Agent connections and
reconnect. The stored connection metadata allows Pip to remove its old commands.

If you use VS Code navigation, install/update the bundled **Pip Session Links**
extension through **Connect VS Code session links…** after replacing Pip. Once
active work finishes, run **Developer: Reload Window**, then **Pip: Refresh Session
Links** in each window. The extension is bundled with Pip; customers do not build
it or install Node/Yarn. Updating the app alone does not reload an extension that
is already running. Insiders users install the new bundled VSIX manually in
Insiders. See the [helper README](vscode-session-links/README.md).

To disconnect, open **Agent connections…**, choose **Disconnect** for that agent,
review the change, then restart/reload the agent after its active action finishes.
Removing the app alone does not remove hooks. Disconnect before moving Pip to the
Trash; custom characters and private local data remain unless you remove them.

The old `install_local.py` flow remains a developer/source-beta installer. It is
not used by the self-contained download and its machine-specific signing plan
must not be applied to a prebuilt signed release.

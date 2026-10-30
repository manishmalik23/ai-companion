# Pip Session Links for VS Code

**Pip Session Links 0.3.0** (`pip-local.pip-session-links`) is our small
TypeScript extension that lets Pip return to the correct VS Code window. It uses
VS Code's public `asExternalUri()` API to obtain a link with a window ID. It does
not open chats on activation, send text, start an agent, or create a terminal.

The helper implements local macOS and native Windows VS Code and VS Code Insiders
windows. **Windows CI exercises the private-file writer; real VS Code installation
and live assistant navigation remain manual acceptance checks.** WSL, remote/SSH,
dev-container windows and other editors remain unavailable. Pip must validate the
lease and request identity before opening a link. Restarting the old 0.2.0 helper
does not add Windows support; install 0.3.0.

## Install or update

For Pip Source 0.7.2-alpha.3, start in `cross-platform/` and run:

```sh
yarn session-links:install
```

This builds the 0.3.0 VSIX and installs it using an existing official VS Code
installation. It does not install VS Code or change agent hooks. For Insiders,
use `yarn session-links:install --insiders`; a named VS Code profile can be
selected with `--profile "Profile name"`. Install into the same profile that
runs the agent. `yarn session-links:build` builds only the VSIX for manual review
and installation through **Extensions: Install from VSIX…**.

After active assistant work finishes, run **Developer: Reload Window** from VS
Code's Command Palette (**Ctrl+Shift+P** on Windows, **⌘⇧P** on macOS), then
**Pip: Refresh Session Links** in each local window. A successful refresh reports
that session links were refreshed for that window.

The native Mac **Pip 0.7.2 / build 46** app bundles the private 0.3.0 VSIX. Its
**Connect VS Code session links…** menu installs that bundled version. The
[Pip 0.7.2 beta 2 release](https://github.com/manishmalik23/ai-companion/releases/tag/pip-v0.7.2-beta.2)
also includes `pip-session-links-0.3.0.vsix` as a standalone asset for manual
**Extensions: Install from VSIX…** installation. Check the extension version
when updating; the older Pip 0.7.1 download contains helper 0.2.0.

Pip's menu installer currently targets standard VS Code. For **VS Code Insiders**,
right-click your installed Pip.app in Finder, choose **Show Package Contents**,
and locate `Contents/Resources/PipSessionLinks.vsix`. Copy the file to Downloads
without moving the bundled original. In Insiders, run **Extensions: Install from
VSIX…**, select the copy, then reload and refresh.
For a different VS Code profile, install the VSIX into the profile that runs the
agent. The usual installed path is `/Applications/Pip.app`; a per-user install
may instead be under `~/Applications`.

The source-built extension appears in VS Code's Extensions view as **Pip Session
Links**, publisher **pip-local**, version **0.3.0**. It is separate from the Claude
Code and Codex extensions, and is not on the VS Code Marketplace. Source users
update it with `yarn session-links:install`, then reload and refresh. The native
Mac menu installs only its bundled version: the Mac 0.7.2 app bundles 0.3.0.
Replacing Pip.app does not update or reload an already installed extension
automatically.

If refresh reports unavailable, select **Pip Session Links** in **View → Output**
for a static failure category. Do not post private chat or command content when
reporting a connection problem. Existing agents/terminals may need to restart
after their current work finishes to inherit the new window identity.

## Role in Pip

Provider hooks remain the source of approval and question events. Pip's bridge
turns supported events into private local requests; the native Mac or TypeScript
app displays them and returns supported decisions. This extension supplies the
other direction: a window-specific route back to the requesting chat or existing
terminal when its session header is clicked. It does not answer Codex questions
or provide agent permission hooks.

In native Pip build 46 and Pip Source 0.7.2-alpha.3, successful navigation also
hands off only the clicked card. The Pip app and bridge return a new permission
request to the host's normal approval flow without allowing or denying it.
Claude structured questions use their existing defer path, while Codex question
notices are only dismissed in Pip and must be answered in their original host.
Other queued requests remain answerable; Pip collapses to the character only
when no other cards remain. Failed navigation or an older permission request
without handoff support leaves its card available with an error. The helper
supplies the route; it does not make the decision. Fixture checks cover the
handoff logic, while live Codex fallback prompts remain an acceptance check.

The helper publishes only local window/workspace/terminal identifiers, validated
link capabilities and the supported Codex extension version. It does not read
chat messages, chat titles, project file contents or terminal output, send
messages, approve requests, create terminals, or execute the tool command shown
by Pip. On Windows it runs a fixed local PowerShell helper to inspect ACLs and
create its private registry directory. It never inserts a displayed tool command
into that helper. Pip's bridge separately performs the exact-session title-metadata lookup described in
the main README. No new API key or server is required for this helper.

## Build and validate

Maintainers need Node 20+ and Yarn 1.22:

```sh
yarn install --frozen-lockfile
yarn test
yarn package
```

The package command writes `artifacts/pip-session-links-0.3.0.vsix`. It uses a
standard VSIX ZIP container and has no runtime npm dependencies. For a manual
installation, users can choose Extensions → Install from VSIX and select the
package. Installing the package does not require a separate Node or Yarn installation.

This source has not been published to the VS Code Marketplace. The build and
pure helper checks do not install it into a real VS Code instance. The local
window connection and header hand cursor were verified on macOS; exact-chat navigation
remains a live acceptance check recorded in [RELEASE_CHECKS.md](../RELEASE_CHECKS.md).

## Window registry

Each window publishes one lease under the platform's registry directory:

```text
~/Library/Application Support/AgentCompanion/.runtime/session-links/<windowKey>.json
```

```text
%LOCALAPPDATA%\Pip\SessionLinks\<windowKey>.json
```

`windowKey` is a new lowercase UUID for each extension activation. On macOS the
directory must be owned by the current user with mode `0700`; lease files use
mode `0600`. On Windows the new registry directory is created with a protected
ACL allowing the current user, SYSTEM and Administrators only, and owned by the
current user. Files inherit that ACL and are checked before any lease bytes are
written; trusted SYSTEM/Administrators ownership is also accepted for files from
elevated processes while the current user's full control remains required.
Existing unsafe ACLs are rejected rather than repaired. The registry must be on
a fixed local drive, not a mapped network or removable drive. Path components
must not be reparse points; workspace paths must be local drive paths, not UNC,
device, alternate-stream or relative paths. The fixed PowerShell inspection runs
asynchronously during refresh to keep the extension host responsive. Updates use
a private temporary file and atomic rename. Refresh failure cleanup is also
asynchronous; only actual extension disposal uses synchronous inspection.
A lease refreshes
every ten seconds and when workspace folders or terminals change. Disposal
removes only that window/process lease. Pip must reject expired leases and dead
extension-host processes if VS Code exits without cleanup.

Schema version 1:

```json
{
  "schemaVersion": 1,
  "windowKey": "11f16f2b-98b5-416c-8f15-700df828a81b",
  "processId": 1234,
  "updatedAt": 1793000000.25,
  "workspaces": ["/Users/example/project"],
  "claudeSessionURL": "vscode://anthropic.claude-code/open?windowId=7",
  "terminalURL": "vscode://pip-local.pip-session-links/terminal?windowId=7",
  "codexSessionURL": "vscode://pip-local.pip-session-links/codex?windowId=7",
  "codexExtensionVersion": "26.1021.22027",
  "terminals": [{ "processId": 2345, "name": "zsh" }]
}
```

The lease is at most 65,536 bytes. `processId` identifies the extension host.
The two `codex` fields are optional and always appear together. They are omitted
when the installed Codex extension version is unsupported or its route is unavailable.
`terminals[].processId` identifies an existing terminal's shell process. Up to 32
absolute local workspace folder paths and 64 terminal identities are included.
No chat messages, terminal output, project file contents, credentials, or network
requests are used. Metadata stays on this computer. These permissions isolate
other unprivileged accounts; they do not defend against another program running
as the same user or an administrator. Windows CI verifies the private-file
lifecycle and rejection of unprotected directories and junction paths. Real URI
navigation and enterprise-specific ACL configurations still need native acceptance.

If `asExternalUri()` does not provide one matching numeric `windowId` for both
links, the helper publishes no lease. It never falls back to a generic URL that
could select a different window or create a fresh Claude conversation.

Resolved and incoming VS Code URIs preserve query delimiters with
`toString(true)` before validation. Version 0.1.1 fixes the default serializer
encoding those delimiters and preventing the window registry from being written.

## Origin identity

The helper sets `PIP_VSCODE_WINDOW_KEY` in the extension host environment for
subsequently started extension child processes. The same namespaced value is
applied to newly created integrated terminals through
`environmentVariableCollection`. Existing running agents/terminals are not
modified. Restart an agent after its current work finishes if it needs the new
identity. The prior process environment value is restored when the helper stops.

An existing Codex background runtime may predate the helper and retain its old
environment when a conversation is reopened. A fresh runtime must start after
the helper is active to inherit the key. This matters when several windows open
the same workspace: Pip requires an exact origin key and leaves an ambiguous
match unavailable rather than selecting another window.

## Link handling

Pip may append a validated session UUID to `claudeSessionURL` as the `session`
query parameter, after confirming the request belongs to that window/workspace.
The Claude extension handles that route and focuses an existing matching tab.

To focus a known existing terminal, append `windowKey` and its exact shell `pid`
to the `terminalURL`. The helper accepts only its own window key and an exact
current `Terminal.processId` match. It calls `Terminal.show(false)` on that
terminal. Missing, ambiguous, closed, or mismatched terminals receive no action.
No arbitrary command or input text is accepted in a link.

### Codex compatibility adapter

Codex IDE extension version **26.1021.22027** has been inspected to accept an
existing local thread route. That route is an internal implementation, rather
than a documented public IDE contract, so this adapter supports exactly that
version. Unknown, missing, or subsequently updated versions receive no Codex
capability. Claude and existing terminal navigation continue independently.

After validating the lease and existing thread identity, Pip appends `windowKey`
and `sessionId` (a thread UUID) to `codexSessionURL`. The helper accepts exactly
those parameters plus its original `windowId`, and checks its own window key.
It rechecks the installed version, resolves the full
`vscode://openai.chatgpt/local/<thread-UUID>` with `asExternalUri()` from that
window, and requires the returned scheme and window ID to match before opening.
The version is checked again after resolution to reject an update during the request.

This opens the existing thread in Codex's sidebar. It does not guarantee selecting
the original editor tab, submit a message, create a task, invoke a command, or run
a CLI resume. The helper does not read thread content or titles. Native Pip must
verify the stored local UUID before requesting navigation.

The explicit **Pip: Refresh Session Links** command refreshes the lease and
reports availability. Startup and periodic updates do not show dialogs. The
output channel reports static failure categories without chat text or paths.
Concurrent timer, event, and manual refreshes share the active result, so a manual
refresh does not report unavailability merely because a registry write is running.
Changes received during that write queue one subsequent refresh.

References: [Microsoft URI handler example](https://github.com/microsoft/vscode-extension-samples/blob/main/uri-handler-sample/src/extension.ts),
[Claude Code session links](https://code.claude.com/docs/en/vs-code#launch-a-vs-code-tab-from-other-tools).

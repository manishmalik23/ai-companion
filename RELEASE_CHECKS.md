# Pip private macOS beta verification

## One-command local Mac installer

Verified on October 30, 2026. A fresh `./build-installer.sh --no-open` run used
the Mac's existing Python 3.14.7, Node 24.18.0 and Yarn 1.22.22, created a new
project-local virtual environment, installed locked packaging dependencies,
built the VS Code helper and produced a self-contained signed DMG. It did not
invoke the portable-Python GitHub release bootstrap. Dependencies still require
approved npm/Python registry access. No DMG or app binary is added to Git.

Five actual CLI checks passed: prerequisite-only mode creates no build files;
missing Python gives setup guidance; existing output directories and dangling
output symlinks are rejected without changes; and a second build fails while
the stable checkout lock is held. Normal completion releases that lock.

All 45 packaged-runtime checks and the ZIP/DMG download checks passed against
the new build, including frozen Claude/Codex hooks, fake chat streaming,
deep/strict signatures, read-only mounting, Applications shortcut and Finder
layout. Only disposable settings were used; no real agent calls were made.
The full build used `--no-open`, so it did not open the finished DMG. The default
command opens that image for the user to drag Pip into Applications and launch.
The installed `/Applications/Pip.app` remained byte-identical to its pre-build
state; source packaging did not install or replace it.

The app version remains 0.7.2 / build 46. This local build measured a minimum macOS
version of 26.0 because of the installed Python runtime; its manifest and readme
report that value. It is a build for this Mac, not a replacement for the official
portable beta 2 download, which remains macOS 13+. Other developers should build
with their own compatible toolchain. This does not change software approval,
host hook trust, or the private beta's ad-hoc signing/notarization status.

## Pip 0.7.2 / build 46 session handoff beta

Verified on October 30, 2026. After a session link opens successfully, the native
app and Source 0.7.2-alpha.3 return only the clicked, unchanged request to its
origin. New permission requests advertise `canDefer: true`; a correlated defer
returns no hook decision, allowing the host's normal approval flow to continue.
Claude questions use existing deferral and Codex question alerts remain notices.
Other queued requests remain available; an empty queue collapses to the character.
Older permission hooks without the capability remain answerable in Pip.

Validation passed:

- The full native check script exited successfully: all 229 Python tests, native
  build, disposable-home fresh-install/update checks and all Swift suites,
  including 58 handoff/freshness/concurrency cases, 452 Appearance cases and
  63 dock cases. No real requests or live model messages were sent.
- All 147 TypeScript tests passed. Permission response schemas, captured request
  snapshots, navigation failures, old capabilities, duplicate/stale completions,
  concurrent source resolution and preservation of unrelated requests are covered.
  Deferred/no-response sessions remain in attention; newer lifecycle documents
  are preserved using the exact publication timestamp.
- Isolated Electron smoke checks passed gallery, themes, queues, typed Other,
  source deferral, Codex notice dismissal and renderer isolation. Synthetic events
  only; no real agent settings or original sessions were changed.
- All 45 frozen-runtime checks passed with a minimal PATH. The exact generated
  Claude and Codex permission-hook commands advertised handoff support, returned
  empty output for defer and removed only their correlated request/response files.
  Synthetic displayed commands were never executed. Existing allow/deny, chat,
  setup and immutable signed-bundle checks also passed.
- Download checks passed deep/strict signatures, bundled runtime execution,
  ZIP extraction, read-only DMG mounting, Applications shortcut, Finder layout
  and SHA-256 checks. The app ZIP is an internal verification artifact.

The packaged build was installed at `/Applications/Pip.app` after verifying no
unexpired request was pending, with graceful termination and an atomic swap.
A verified build 45 backup was retained. It reopened as build 46 with a new PID
and fresh heartbeat. Settings, hooks, canonical preferences and appearance hashes
were preserved; an existing expired notice was left untouched.

For a fresh real Codex permission request, the user clicked the blue session
title and confirmed that Pip's card closed and the request could be approved
in Codex. The read-only `/bin/ls -ld /Applications/Pip.app` test then completed
with exit status 0. This verifies the local Mac approval handoff for that host;
it does not establish every supported route or the TypeScript/Windows UI.

The published download set is DMG, optional helper 0.3.0 VSIX, readme and a hash
manifest. Developers clone the repository. GitHub's automatically generated tag
source archives remain separate from uploaded assets. The private Apple silicon
beta still requires macOS 13.0, is ad-hoc signed and is not notarized. Other Codex
host combinations, thread-render acknowledgement and native Windows UI remain
manual acceptance checks; automated navigation tests use fixtures and existing dispatch
success contracts. Mini Chat remains a native Mac feature.

## Pip 0.7.2 / build 45 downloadable beta

Built and verified on October 30, 2026 from the merged character-gallery and
Windows mailbox changes in PR #10, with the native tile-click and direct Mini
Chat fixes on the release branch. Build 45 supersedes the unpublished build 44
candidate. The native app, nested runtime and helper
report 0.7.2; the source TypeScript app is 0.7.2-alpha.2. The Mac download bundles
the optional Pip Session Links 0.3.0 VSIX. Windows remains a source-run alpha
without a Pip executable or installer, and native Windows UI acceptance remains
separate from component CI.

The self-contained Apple silicon package uses the pinned, SHA-256-verified
portable Python 3.12.15 environment and locked packaging dependencies. Its
minimum macOS version is 13.0. It is ad-hoc signed and not notarized, as with the
previous private beta.

The native gallery now tracks mouse presses over the full custom-drawn tile,
including its artwork, name and corners, and reuses decoded built-in previews.
The hover controls contain Claude, ChatGPT and Mini Chat. The first two retain
their installed-app routing; Mini Chat opens the existing native chat directly
with explicit Claude Code and Codex CLI provider labels. It keeps its own
conversations rather than reading desktop/editor chat history. Source Mini Chat
has not been ported to the TypeScript app.

The complete default native check script reached every passing stage: 220 Python
tests, native build and disposable-home fresh installation/update, all existing
Swift suites, 452 Appearance checks and 63 new dock checks. The latter exercise
full-area cell hit testing with real NSEvent fixtures, independent callbacks,
hover geometry, drag handlers, hidden provider-picker routing and offscreen
light/dark/chat previews. These checks do not post desktop input or send real
model requests. The opt-in interactive question-focus check was not run.

The final package passed all 33 frozen-runtime checks with a minimal PATH and
disposable settings, covering generated hooks, allow/deny responses, async
question notice retirement, exact Claude/Codex title lookup, fake streaming
chat, connection/disconnection and an unchanged signed bundle. These checks
send no live model requests and require no external customer Python runtime.
The app and nested helper versions, all eighteen character PNGs, shared layout
JSON and exact bundled helper 0.3.0 VSIX were verified against build inputs.

Download checks passed ZIP extraction, deep/strict signatures, bundled runtime
execution, read-only DMG mounting, the Applications shortcut, Finder icon
positions, installer background and SHA-256 hashes. Generated app bundles and
archives remain outside Git; release assets are distributed through Releases.

The packaged app was installed at the existing Applications path using a
verified old-app backup, a guarded no-active-request check, graceful termination
and an atomic same-volume swap. Both candidate updates reopened through the
normal macOS launcher with a new process and fresh heartbeat. The final update
retained a verified build 44 backup. Configuration, hook files, canonical
preferences and appearance hashes were unchanged by the updater, including the
user's saved Chai choice. An existing expired notice was left untouched. Live
Appearance inspection of the preceding build 44 candidate showed all thirteen
enabled choices and successful saved/applied feedback. Custom picker interaction,
live signed-in Mini Chat reply completion and Windows native UI remain separate
manual acceptance checks.

## Six fluffy companions in both Appearance galleries (source change)

Verified on October 30, 2026. Native and TypeScript source builds append Peach
Puff, Lavender Mochi, Mint Bean, Nimbo, Chai and Plumo to the original six
companions. Both galleries offer thirteen choices including Default Pip, scroll
on smaller displays and preview Idle, Working and Waiting. Built-in choices
persist by catalog ID; default reset and existing custom-image profiles remain
supported. This source change does not replace the published 0.7.1 Mac download.

The six new 1254 × 1254 alpha PNG sheets and shared `FluffyLayouts.json` are
bundled by native builds, TypeScript builds and the source ZIP. Both renderers
validate the layout header, complete catalog, filenames, cell-contained integer
crops and common canvas dimensions. They center and bottom-anchor those crops
at a constant scale. The TypeScript build embeds the JSON locally and keeps
`connect-src 'none'`; no character or layout download is needed at runtime.
The new sheets use their own eyes, laptop frames and waiting artwork, without
the default robot's overlays. The earlier six renderer paths remain supported.

Windows CI exposed an existing sharing error while replacing `heartbeat.json`
during a real hook subprocess check. The TypeScript mailbox now retries only
Windows EPERM/EACCES/EBUSY rename failures within a 300 ms monotonic retry budget,
using the same completed temporary file. Before retrying, it checks unchanged
root/parent, temporary-file and target snapshots using BigInt identities and
file timestamps. It never removes the target or changes permissions, and cleanup
leaves substituted files/directories alone. Other errors and POSIX failures
retain immediate failure behavior. Nine deterministic fixtures cover recovery,
exhaustion, deadline, nonretryable errors and substitution/cleanup paths.

Final Lavender Mochi and Mint Bean sheets were regenerated with extra clearance.
The reproducible measurement passes all 72 main-component frame bounds without
cell-edge clipping; regenerated JSON matches the checked-in resource byte for
byte. The final PNG provenance hashes and source archive copies match exactly.

Local verification passed:

- `./scripts/check.sh`: all 220 Python tests, native app build, disposable-home
  fresh installation/update and all Swift suites. Character checks include 604
  rendering/layout cases, 276 Appearance/import/persistence cases and 19 original
  robot animation regressions.
- `yarn test`: all 127 TypeScript tests, including metadata validation, timing,
  stable selection IDs, old/custom character behavior and packaged-asset parity.
- `yarn smoke`: isolated real Electron checks for thirteen loaded tiles, all
  twelve companion previews in three states, all six new apply/save/reset
  round trips, smaller-window scrolling, themes, renderer isolation and existing
  approval/question/queue flows. Captures scroll the full preview and its state
  controls into view before recording. Synthetic events only.
- AppKit offscreen light/dark galleries and Electron captures were visually
  inspected. New character anatomy and laptops are complete; labels fit and the
  last tile and controls remain reachable.
- Source ZIP integrity, inclusion of all sheets/metadata/provenance tooling and
  `git diff --check` passed. Generated ZIPs and app builds are not tracked.

No real agent requests were answered, current hook settings changed, extension
installed or existing Pip replaced by these checks. Native interactive selection
and Windows desktop rendering/selection remain separate manual acceptance
checks. Windows/macOS component CI and native Mac checks run on the PR.

## Source 0.7.2-alpha.1 and Session Links 0.3.0 (Windows integration)

The private helper now activates on native Windows as well as macOS. The source
app offers `yarn session-links:install`, with a build-only/manual-VSIX alternative,
explicit Insiders/profile options and reload/refresh instructions. It does not
create a Windows app executable or installer, or publish a Marketplace extension.
The helper appears under Extensions and supplies no Chat Agent/sidebar icon.

Windows leases use `%LOCALAPPDATA%/Pip/SessionLinks` on fixed local storage.
New directories receive protected private ACLs at creation; existing ACLs are
never modified. Directory ownership must match the current user. Files may have
the current user or trusted SYSTEM/Administrators ownership, but the current
user must retain FullControl and no other principals may have access rules.
Reparse points, mapped/network registry drives and ambiguous Win32 path aliases
are rejected. The helper and reader share byte-identical security modules.

Windows UI lease inspection refreshes asynchronously without blocking approval
updates. Clicking always awaits a separate fresh inspection. Window keys,
matching workspace components, live extension-host PID, exact session UUID,
numeric URI window ID, ambiguity rejection and the existing Codex version
allowlist remain required. This does not add remote/WSL/container links or
standalone Windows Terminal navigation.

On macOS, all 111 app tests passed. Helper checks passed 44 tests and skipped the
one real-Windows private-ACL integration test. The real source-to-VSIX build
command, VSIX manifest/ZIP/module checks, unchanged security-copy check,
Electron smoke test and native Mac source build passed. No extension was
installed into the user's VS Code, and no live hook settings or app were changed.
Future source Mac builds bundle helper 0.3.0; the existing published Mac app
remains version 0.7.1 with its original helper 0.2.0.

A scoped Windows/macOS GitHub Actions workflow uses full commit SHA pins for the
official Node 24 actions. Windows CI has exercised the real private-ACL lease
create/write/replace/remove path and extension packaging. The app suite also
checks decoded hook arguments so Windows' encoded PowerShell transport is tested
without assuming a raw POSIX command string. Windows VS Code installation,
native UI focus and live assistant navigation remain manual acceptance checks.

Final CI at code commit 2f1c2e3
passed on both Windows and macOS. Windows passed 37 helper tests (8 POSIX-specific
skips) and 110 app tests (1 platform-specific skip). Its native fixture verified
the private-file lifecycle, rejection of an existing unprotected directory with
an unchanged ACL fingerprint, and rejection of an NTFS junction. macOS passed
44 helper tests (the Windows-only fixture skipped) and all 111 app tests.

The HTTP size-limit fixture sends over-limit headers without uploading the body
and requires an immediate 413 response. This avoids an OS-dependent TCP reset
when a rejected upload races connection closure. Request failures carry case
labels, and Windows CI repeats the receiver suite five times after the app checks
to catch recurrence of the observed intermittent failure.

## Pip 0.7.1 session subjects and action-button cursors

Prepared as version 0.7.1 / build 43, with TypeScript source 0.7.1-alpha.1.
Claude subject lookup now checks only dedicated custom-title and ai-title records
in the first and last 64 KiB of the exact session JSONL file, alongside its
custom-title sidecar. Complete, schema-checked, matching-session records are the
only candidates; message, tool and summary records never supply a subject.
The reader follows Claude Code 2.1.312's observed title precedence. Unsupported
formats fall back to the labelled pending task instead of inferring a chat title.

Codex lookup checks the latest bounded 256 KiB of its title-only session index,
so a growing index no longer disables all subject lookup. Native Pip retains its
immutable read-only database fallback restricted to name/cwd metadata; the
TypeScript reader uses the index only. Explicit, stored and cached candidates
are checked against the workspace and session ID before selection. The renderers
also reject technical-ID and workspace labels as primary subjects. Workspace
context remains visible below the subject.

Enabled Allow once, Reject, question submit/defer, dismiss and paging controls
now use a pointing-hand button base with separate background-hover and active-app
cursor tracking. Native cursor regions are rebuilt while the panel is non-key;
hover does not activate Pip or make a permission decision. Disabled controls
keep the arrow. The idle provider buttons use the same cursor behavior.

The full source checks passed 220 Python tests, fresh-install verification and
all native suites, including 94 navigation, 59 header and 16 action-button cursor
checks. TypeScript passed all 100 tests. The Mac Electron smoke test passed
approval/denial, question input, concurrent queues, themes, character selection
and external-decision clearing using synthetic events and a disposable profile.
Read-only local diagnostics found saved Claude and Codex names for their exact
session IDs. No real provider request was answered by these checks. Physical
hover over the updated action buttons remains a manual acceptance check.

The final self-contained app passed all 33 frozen-runtime checks with a minimal
PATH. The DMG passed checksum verification and a read-only mount check of its
strict embedded signature, version/build, Finder layout, Applications drag
target and matching native executable/VSIX bytes. The image was detached after
verification. Pip 0.7.1/build43 was installed locally and reopened, with provider
settings and appearance hashes preserved. The previous app remains in a
recoverable local backup. The update did not rewrite pending approval snapshots
or answer any live request.

Windows remains untested; no Windows executable or installer is included.

## Pip 0.7.0 built-in character gallery

Prepared as version 0.7.0 / build 42. Appearance offers Default Pip plus Sunny,
Mochi, Boba, Lumi, Mallow and Sprout, with idle/working previews and an explicit
Use character action. Default selection and Reset restore the original robot.
Custom still-image and animated-sheet imports remain available.

Built-in profiles use version 2 and save only the known catalogue identifier;
legacy version-1 custom profiles retain their embedded image data. Tests cover
switching, preview-before-apply, persistence, default reset, invalid payloads and
custom-profile compatibility. The artwork is bundled locally; alpha checks
confirmed transparent backgrounds in all twelve 1254-square source PNGs.

The renderer isolates each standing/seated pose and overlays registered eye
patches for a 160 ms blink every 5.2 seconds. The original body and laptop remain
fixed. A waiting badge is shared with the default character. Source prompts and
asset provenance are included under design/characters and ASSETS.md.

The full source check script passed 199 Python tests, fresh-install verification,
and all native suites, including 128 built-in rendering checks, 58 appearance
checks, 19 original animation checks, 94 session-navigation checks and 38 header
checks. All six idle/working/blink/waiting previews were visually inspected.
The final package passed 29 frozen-runtime checks. Read-only DMG verification
confirmed the strict embedded signature, version/build, Applications drag target
and all twelve character files matching the source assets. Packaged light/dark
Appearance screenshots show every gallery choice and the original default robot.

Pip 0.7.0/build42 was installed locally with settings and character hashes
preserved. The installed Appearance UI exposed all seven enabled radio choices.
The user selected Lumi; a valid v2 identifier-only profile was saved (74 bytes),
and the live desktop companion displayed Lumi in the laptop working pose. The
app heartbeat remained fresh. No provider permission settings changed for the
gallery feature.

## Pip 0.6.1 session navigation and approval clarity

Prepared as version 0.6.1 / build 41 for the private beta. Apple documents that
`activeAlways` suppresses `cursorUpdate` events, and that cursor invalidation
normally defers rebuilding until the window becomes key. The header now uses
separate active-always hover and active-app cursor-update areas and explicitly
rebuilds the window cursor regions after card layout and presentation. It does
not activate Pip or take keyboard focus on hover. All 38 header checks passed,
including a real AppKit cursor-region rebuild on a non-key inactive panel.
The 94 navigation checks and 29 packaged-runtime checks also passed.

Build 39 was installed with settings and character hashes preserved; the strict
installed signature and fresh heartbeat were verified. A real Codex waiting-question
card displayed the saved subject and enabled session header. With VS Code active,
the user hovered over its blue title and confirmed: **The hand appears before
clicking**. This verifies physical hover for that local Codex card. Exact-chat
click navigation remains a separate acceptance check.

Build 40 also removes the repeated REASON section from the scrolling details.
The supplied explanation remains near the top under WHY THIS IS NEEDED; the
scroll area starts with ACTION. Build 41 additionally omits top-level explanation
metadata from the displayed JSON only when it matches the reason already shown
above. Commands, paths, nonmatching/nested fields and the original request bytes
used for approval remain unchanged. Light and
dark approval previews were rendered and visually checked. The full source
check script passed all 199 Python tests, fresh-install verification, and all
native suites, including 94 navigation and 38 header checks.

The display-only filtering passed 23 action/detail checks, including retention
of nested/nonmatching fields, bounded parsing and unchanged request/snapshot
bytes. Build 41 was installed locally with settings and character hashes
preserved; its strict signature and fresh heartbeat passed verification. The
user confirmed **Yes, the reason appears once** on the updated app.

The final build 41 release passed all 29 frozen-runtime checks. DMG checksum
verification passed; a read-only mount confirmed version 0.6.1/build41, the
Applications symlink, Finder layout, strict embedded signature, and matching
native executable/VSIX bytes. The image was detached after verification.

## Pip 0.6.0 subjects, Codex IDE links and hover feedback

Prepared as unreleased version 0.6.0 / build 38. Published downloads remain 0.4.2.

The header now shows a saved subject, with provider/host/workspace below it.
Missing subjects use a labelled task description or friendly action/provider
fallback. UUIDs remain in tooltip/accessibility/copy details instead of being
drawn in the header. The control requests hand and arrow cursors through AppKit.
The original handler tests did not establish that the visible system pointer
changes while another app is active; that claim remains unverified.
Light/dark subject previews were rendered and visually checked.

Title lookup is limited to exact-session provider metadata: Codex's title-only
index, an immutable read-only database name lookup, or Claude's custom-title
sidecar. It does not use legacy database prompt text, conversation bodies or raw
prompts. The current Codex session's title was found locally in 2.33 ms; the
diagnostic reported only its presence and length. Source installs also copy the
new module, with an installed-bridge import regression check outside the checkout.

Helper 0.2.0 provides a window-bound Codex route. It checks the window key, UUID,
scheme and query, resolves the exact full route inside the target window, and
rechecks the extension version before opening. The installed Codex route is not
a documented public interface, so this adapter currently allows only extension
26.1021.22027. Unknown versions leave Claude and terminal links available.

The full source run passed all existing native suites, 94 navigation checks and
36 model/control header checks. After the source-installer dependency fix, all
199 Python tests passed. The helper passed 27 tests and VSIX integrity checks.
The frozen app passed 29 packaged-runtime checks, including index and SQLite
subject lookup without modifying provider metadata. These checks made no model
requests and did not control Terminal or post UI events.

Pip 0.6.0 / build 38 and helper 0.2.0 were installed locally. App signatures,
bundled helper hash, fresh heartbeat, and preserved settings/character hashes
were verified. On October 29, the running VS Code host published a fresh lease
with Codex capability and extension version 26.1021.22027. A live exact-Codex-chat click and physical mouse hover
check remain pending. The earlier build 37 Apple Terminal manual acceptance
remains recorded below.

## Pip 0.5.2 Terminal navigation diagnostics (development)

Prepared October 28, 2026 as an unreleased development build, version 0.5.2 /
build 35. Published downloads remain 0.4.2.

The reported Terminal error previously combined exited processes, missing tabs,
and all other script failures. Saved PID, start-time, and tty metadata for both
live Claude Terminal sessions matched macOS. A headless check using the actual
native identity verifier accepted both live sessions and rejected changed start
times. The serial background AppleScript execution model is supported on current
macOS; mixed-case handler dispatch also passed a pure in-process echo check.

The native selection path now distinguishes a missing or changed tab, ambiguous
tab identity, selection limits, unexpected replies, permission/timeout errors,
and other script failures with a numeric error code. Raw script error text and
unknown reply strings are not exposed. All 63 native navigation checks passed,
including the actual typed invocation against a pure echo handler. These checks
did not select a tab or request Automation access. Live Terminal diagnosis is
still pending; this diagnostic change alone is not a verified navigation fix.

The diagnostic build was installed with settings and character hashes preserved.
A local, non-answerable navigation check using a captured live terminal context
then produced AppleScript error -1728; the error was observed through the desktop
tool and confirmed by the user. The process checks and Automation check had
therefore passed before script execution failed.

Build 36 replaces window-ID/tab-index reconstruction with the existing matched
window/tab values, selects the tab through its declared `selected` property, and
raises the matched window through `frontmost`. The full scan, unique tty match,
revalidation, and PID/start-time protections remain. Typed script failures now
include only a whitelisted operation and numeric code. All 79 native navigation
checks passed, including pure fixtures for typed error transport and retaining
matched objects across later loop iterations without reading tab contents.
Live acceptance of the revised selection path remains pending.

Build 36 was installed, and the user reported the staged failure while reading
Terminal tabs. Build 37 reads cached list items by numeric index and tolerates
only error -1728 from a window's tab-enumeration query, allowing other windows
to be examined. Other errors still stop navigation. If incomplete enumeration
prevents finding a match, the staged enumeration error remains; it does not
pretend that the session exited. Exact matching, duplicate rejection, and final
identity checks remain. All 80 native checks passed, including an unreadable
window followed by a matching tab and a permission failure that must not be
ignored. The desktop-control tool blocks direct Terminal access; final selection
acceptance must be performed by the user through Pip.

The final build 37 passed all 25 packaged-runtime checks and was installed as
Pip 0.5.2 / build 37 with settings and character hashes preserved. Its installed
signature and fresh heartbeat were verified. The user clicked the newly sent,
clearly labelled local navigation card and confirmed **Opened the correct
Terminal tab**. This exercises the production header and selector using an
actual captured Claude terminal identity; it does not execute a command, send a
model message, or answer an approval. The temporary card is no longer present.
Other host routes and a full live provider-approval/navigation cycle remain
separate acceptance checks.

## Pip 0.5.1 Codex async-question alert fix

Prepared October 28, 2026 as an unreleased development build, version 0.5.1 /
build 34. Published downloads remain 0.4.2.

A live read-only `hooks/list` check confirmed that the installed Pip hooks were
enabled and trusted. The missing demo question had a matching `PostToolUse`
retirement record for `request_user_input_async`. This tool returns an immediate
acknowledgement before the user answers, so the old bridge removed its alert
before the native UI could poll it.

The fix excludes only Codex async question notices from acknowledgement-based
retirement, including acknowledgements recorded before notice publication.
Synchronous questions, permission requests, Claude forms, failure cleanup,
source/session isolation, and the two-minute expiry retain their prior behavior.
Codex answers still belong in Codex. Existing hooks do not report the exact async
answer event; turn/session cleanup or expiry may clear an alert before a later
answer. This is a bounded notification rather than an answerable Codex form.

The full Python suite passed 182 tests. The bridge suite passed 57 tests,
including four new regression methods for
acknowledgement retention, the publication race, scoped lifecycle cleanup, and
unchanged permission retirement. The packaged-runtime suite now also exercises
both publication orders through the actual frozen helper without model calls.

The final self-contained app passed all 25 packaged-runtime checks and was
installed locally as 0.5.1 / build 34. Agent settings and character hashes were
preserved, the previous app was backed up, and Pip was reopened. A repeat
question was sent in the existing Codex chat; the user reported that its Pip
alert appeared, with Dismiss rather than answer controls. This confirms the
notice path, not answer submission from Pip or exact answer-based dismissal.

A read-only audit of installed Codex IDE extension 26.1021.22027 found no public
answer command, activation API, URI action, or desktop-bridge endpoint. Its
native question answers travel through its private webview/app-server transport.
The documented app-server protocol supports responses for a client owning that
connection; it does not establish a supported way for this helper to answer the
existing IDE question. Codex answer controls and synchronized native-question
resolution remain unimplemented.

## Pip 0.5.0 session navigation development build

Prepared October 28, 2026 as an unreleased development build, version 0.5.0 /
build 33, for Apple silicon and macOS 13+. Published downloads remain 0.4.2.

Permission and question cards now show a session name or explicitly labelled
workspace fallback, followed by the session ID, at the top. Eligible headers
offer navigation through a window-bound Claude Code link, an existing VS Code
terminal process, a verified existing Apple Terminal tab, or a Codex desktop
local-thread link. Unsupported or ambiguous origins remain informational.
Navigation does not answer the request, create a terminal, or execute an agent
command.

The source passed 178 Python tests and the full native suite, including 46 new
session-navigation checks. These cover bounded labels, legacy records, validated
host routes, private registry files, stale or mismatched process identities,
window binding, ambiguous origins, and rejected injected URLs. The Apple Terminal
script was compiled without executing it or requesting Automation permission.
Six approval/question/header previews were rendered and visually reviewed in
light and dark appearances, including long titles and an enabled header.

The self-contained development app passed 19 packaged-runtime checks, 17
installation checks in a disposable Applications folder, and 8 loopback receiver
checks using its frozen helper. These checks did not modify real agent settings,
send model messages, or demonstrate navigation in an actual host.

The first live helper refresh exposed percent-encoding of VS Code's window query
separator. The corrected helper uses VS Code's validated URI serialization at
all route boundaries. Helper 0.1.2 passed 19 checks, including concurrent manual
and periodic refreshes sharing their result without a false unavailable alert.
After reloading VS Code, the user reported a successful refresh, and a fresh
window-bound helper lease was verified locally. An end-to-end click on a real
session remains pending. Apple Terminal Automation consent and
selection, Codex desktop navigation, another Mac, and multiple-window host
acceptance also remain unverified. Codex IDE chats, remote hosts, iTerm2, and
detached or unidentified agent origins are not enabled navigation routes.

The final package containing helper 0.1.2 passed its 19 packaged checks again.
It was installed locally at `/Applications/Pip.app`, verified before and after
replacement, and reopened through macOS. The installed version is 0.5.0 / build
33. Agent settings and custom-character files retained their hashes, and the
previous 0.4.2 app was kept as a backup. The robot and fresh heartbeat were
verified. The corrected extension is now loaded and publishing a fresh local
connection; navigation through a real request header remains pending.

## Pip 0.4.2 question input fix

Prepared October 28, 2026 for Apple silicon and macOS 13+.

Selecting **Other** or clicking its text field now explicitly activates the
companion and focuses the editor. A second focus pass runs after the originating
click and app activation finish. The field scrolls into view, and an existing
editor keeps its cursor position. Requests arriving in the background still do
not activate the app automatically.

The interactive input check covers focus, field-editor text entry, scrolling,
blank-answer validation, cursor preservation, switching between preset and custom
answers, draft preservation, and appearance changes. It uses a temporary panel
and sample text without contacting an assistant. Run it explicitly with
`PIP_CHECK_INTERACTIVE_FOCUS=1 ./scripts/check.sh` on an unlocked Mac desktop.

The final 0.4.2 / build 32 source passed all 151 Python tests and the complete
native check run, including 11 interactive question-input checks. The rebuilt
self-contained app passed 19 packaged-runtime checks, 8 receiver checks using
the actual frozen helper, and 17 installation checks including a copy into a
disposable Applications folder. The ZIP and read-only mounted DMG passed strict
signature checks, bundled helper execution, archive hashes, Applications shortcut,
and Finder installer metadata checks. The disk image was detached afterward.
These checks did not send live model messages or change real agent settings.

The release remains a self-contained, ad-hoc-signed private beta without
notarization. Another physical Mac, Intel hardware, downloaded quarantine behavior,
and live Claude Code question acceptance for this release remain unverified.

## Previous Pip 0.4.1 installer private macOS beta

## GitHub private-beta candidate

The candidate prepared in this repository passed the
full source checks (151 Python tests and all native suites below). The app was
rebuilt from the repository source, preserving its clone/update/contribution
instructions and using a synthetic example path in the approval preview.
The rebuilt frozen runtime passed 19 packaged checks, the receiver passed 8
loopback checks with the actual helper, and the installation suite passed 17
checks including copying the real app into a disposable Applications folder.
The rebuilt ZIP/DMG passed hashes, strict signatures, bundled helper execution,
Applications shortcut, and Finder metadata checks. No real installation/settings
were changed or model requests sent by these checks.

A separate read-only Codex `hooks/list` diagnostic found the user's installed
Pip definitions enabled but **modified**, including `PermissionRequest`. They
need review and trust in the originating Codex host; installing a connection
does not grant that trust. Live acceptance from that host remains pending until
the user reviews the changed definitions and a real request is observed.

## Earlier installer revision 2 checks

Installer revision 2 (October 23, 2026) adds an original background with both
steps: drag Pip onto Applications, then open Applications and double-click Pip.
It explains that the robot appears after opening the app. The background was
rendered and visually inspected. Read me, README, and distribution instructions
now distinguish copying, launching, and the older Pip Preview development app.
The app and runtime are unchanged from the verified 0.4.1 release; the ZIP hash
is identical. The revised DMG and ZIP passed archive hash verification, strict
signature verification, and frozen helper execution. The mounted DMG's shortcut,
updated icon positions, background, and toolbar metadata passed, then it was
detached. No user app was installed/replaced, model invoked, or agent settings
changed. A fresh physical second-Mac install remains untested.

Verified October 23, 2026 on this Apple silicon Mac (macOS 26.7.1).

The DMG now has a Pip → Applications icon layout and arrow background. Opening
the packaged app before installation shows the native Move to Applications / Quit
prompt before starting the companion runtime. The prompt's live accessibility
tree was checked; the test prompt was closed without installing the app. Actual
click-through installation and relaunch remain a manual acceptance step.

The full source checks passed, including all 151 Python tests, the existing Swift
suites listed below, and 15 new app-installation checks. Copying the actual signed
release into a disposable Applications folder and starting its frozen helper
increased the installation suite to 17 passed checks. The checks cover validation
before replacement, explicit replacement consent, rejecting unrelated apps and
symlinks, recoverable old copies, rollback on publication failure, staging cleanup,
and preservation of unrelated data. No real app, settings, or Trash were changed.

The final bundled runtime passed 19 packaged checks, and its native approval
receiver passed 8 real loopback checks with disposable data. The extracted ZIP and
read-only mounted DMG both passed strict signature verification and ran their
bundled helper. Archive SHA-256 hashes, Applications shortcut, icon locations,
icon size, arrow background, and hidden toolbar settings passed. FinderInfo changes
on the signed app are deliberately avoided: hiding its extension in the disk image
would break strict signature verification. The DMG was detached after validation.
No live model messages were sent or real agent connections changed.

The package remains self-contained for Apple silicon / macOS 13+, ad-hoc signed,
and not notarized. A physical second Mac, Intel, older macOS, and a downloaded
quarantined copy have not been tested. The 0.4.0 limitations below still apply.

## Previous self-contained private macOS beta (0.4.0)

Verified October 23, 2026 on this Apple silicon Mac (macOS 26.7.1).

The full source checks passed: 151 Python tests, 32 native mailbox checks,
6 bundled-runtime resolution checks, 11 action-detail checks, 8 real loopback
receiver checks, 206 desktop-observer fixtures, 58 conversation-state checks,
138 light/dark bubble checks, 24 appearance checks, 29 Codex activity checks,
and 19 animation checks. Fresh source installation, repeated update, signature
verification, settings preservation, and custom-profile preservation passed in
a disposable home. The new connection setup window was rendered and visually
checked in light and dark appearance without changing the system theme.

The final frozen runtime passed 19 additional checks with a minimal system PATH
and unavailable external Python environment paths: generated connection commands,
settings preservation/backups, approve/deny request round trips, non-execution of
displayed tool commands, synthetic streaming chat, telemetry dispatch, disconnect,
native library dependency audit, and an unchanged signed bundle. The native
receiver also passed its 8 checks using the actual frozen helper. No live model
requests were sent. The ZIP was extracted and the DMG mounted read-only; both
copies passed strict signature verification and ran their bundled helper. The DMG
Applications shortcut and release SHA-256 hashes were verified, then it was
detached. The Apple silicon DMG is approximately 14 MB.

Version 0.4.0 includes first-launch reviewed connection setup and a precompiled
Swift app with a frozen Python helper. Machine-specific configuration stays
outside the bundle. The build runtime is pinned Python 3.12.15, verified against
Astral's release hash, with upstream dependency licence notices included.
Dependency scanning checks the actual minimum macOS rather than changing a label
to hide a newer runtime dependency. The local package targets Apple silicon and
macOS 13+. This minimum is a binary deployment-target audit, not a test on a
physical macOS 13 machine.

Private-beta limitations: ad-hoc signed without Developer ID/notarization; no
second-Mac, Intel-hardware or live-host acceptance test of this new package yet.
Real assistant sign-in and host hook trust remain user steps. The Developer ID
and notarytool build options are prepared but unverified without credentials.
Ordinary ChatGPT desktop conversation reading remains unavailable. The running
installed companion and real agent settings were not changed during these checks.

## Earlier source-beta verification (0.3.19)

Verified October 13, 2026. This is a source-built private beta with an ad-hoc
signature. It is not a notarized, general-distribution installer.

## Automated verification

`./scripts/check.sh` builds from source and runs:

| Check | Result |
| --- | --- |
| Python bridge, chat, installer, telemetry and activity suites | 142 tests passed |
| Native mailbox | 32 checks passed |
| Desktop observer synthetic trees | 206 checks passed |
| Conversation state | 58 checks passed |
| Light/dark conversation bubble rendering | 138 checks passed |
| Character import, persistence, reset and legacy atlas formats | 24 checks passed |
| Codex hook activity state | 29 checks passed |
| Robot animation, stationary laptop and slow blink | 19 checks passed |
| Real app build | Passed from a clean source copy without old artwork |
| Fresh install and update | Real app installed and signature verified in a temporary home; hooks configured, custom profile preserved, settings unchanged on repeated install |

The installed Pip 0.3.19 also passed strict signature verification and the local
approval receiver returned 200 for an authenticated empty request and 401 for an
unauthenticated request. The checks never submit approval decisions or real model
messages. Synthetic fixtures do not establish compatibility with every host.

## Environment

The checks ran on an Apple Silicon Mac reporting macOS 26.7.1. CLI versions
present were Claude Code 2.1.291 and Codex CLI 0.162.0-alpha.17.2. These are
observed versions, not a guarantee that every older/newer release or IDE path is
supported. Hook availability and explicit trust still depend on the host.
Another physical Mac and Intel hardware have not been tested.

## Manual acceptance still pending

1. Open Pip → Appearance… → Animated sheet → Choose character….
2. Select `desktop/Resources/PipSpriteSheet.png` from this repository.
3. Click Use character; confirm the filename changes and the desktop character works.
4. Click Reset to default; confirm the label returns to Default robot · Animated.
5. Quit and reopen Pip; confirm the default returns correctly.
6. On another Mac, build, install, trust the hooks, and try an actual permission
   request requiring approval. Verify both Approve and Deny, plus resolving a
   Claude request in VS Code while Pip is open.

The desktop-control tool was unavailable during this verification. The user has
not yet performed the native file-picker test. Automated import/reset coverage
passed, but live file-picker acceptance and another-Mac installation remain
unverified.

## Supported scope and limits

- Local Claude Code and Codex hooks supply activity and permission requests.
- Approve once and Deny apply only to the matching request. The host executes it.
- Claude structured questions have forms; Codex questions are notifications to
  answer in the originating host.
- Claude decisions made in its original UI can clear correlated cards through
  the authenticated loopback receiver; some sandbox-network alerts still need
  completion, expiry, or manual dismissal.
- Claude desktop chat reading is experimental and requires Accessibility.
- Ordinary ChatGPT desktop Chat titles/replies are unavailable. Its button opens
  the desktop app; missing-app mini-chat fallback uses the Codex CLI.
- Codex/VS Code task activity does not create conversation Thinking bubbles.
- The original Pip mascot is bundled; the previous OpenAI artwork is excluded
  from this source archive and app build.
- Updates to the ad-hoc-signed binary may require refreshing Accessibility.
- Stable Developer ID signing/notarization is deferred; no certificate or
  Apple Developer membership is available on this Mac. The prebuilt app keeps
  machine-specific configuration outside its signed bundle. The optional
  Developer ID and notarization build path still needs credentialed validation.

## TypeScript source alpha — October 29, 2026

`cross-platform/` adds Pip Source **0.7.0-alpha.1**, an Electron/TypeScript alpha
based on the native Mac companion's interface and core approval workflows. This
change does not replace the Swift app, rebuild its DMG, or produce a Windows
installer/executable package.

Verified on this Apple silicon Mac with Node **24.18.0**, Yarn **1.22.22**,
TypeScript **7.0.2** and Electron **44.7.0**:

- `yarn install --frozen-lockfile` and `yarn build` pass.
- All **76** Node tests pass, including actual hook stdin/stdout subprocesses,
  question answers, request correlation, expiry/replay checks, private file
  handling, exact owned-hook migration, resumable restoration and authenticated
  loopback decision handling.
- `yarn smoke` passes in a real isolated Electron window. It checks all seven
  character choices, persistence/reset, working previews, light/dark renders,
  a smaller display layout, literal tool text, approve/deny, actual insertion of
  typed Other text, focus and draft preservation while another request arrives,
  queue paging, source defer, Codex notice dismissal and disappearance of exactly
  one of two cards after a simulated external Claude acceptance.
- The sandboxed renderer exposes no Node globals. Narrow main-frame IPC,
  restricted navigation and a local-only CSP remain enabled. UI previews were
  visually inspected. Files generated by the checks stay ignored.

All hook and decision events in these checks are synthetic. No model messages
were sent and no real agent settings were changed. Actual live-host integration
for this new runner remains an acceptance step.

**Windows has not been run or tested on a Windows machine.** Windows launcher
fixtures do not establish native execution, display scaling, focus/typing,
click-through/dragging, ACL/reparse behavior or live Claude/Codex integration.
Exact Windows session navigation, all Terminal-tab selection, desktop chat
reading and mini-chat are not available in this alpha. The source guide states
these limits and the remaining acceptance checks. Source execution still uses
Electron's own platform binaries and follows organizational software policy.

## Private source package

Run `python3 scripts/package_beta.py`. It produces a source ZIP under
`.build/releases`, includes a SHA-256 file manifest, and verifies archive
integrity. Runtime data, chats, configuration tokens, builds, install plans,
Git metadata, and old provider artwork are excluded. Users build and install
from source using README.md. No GitHub upload is performed by this command.

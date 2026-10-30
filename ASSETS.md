# Pip character artwork

The source-run TypeScript app in `cross-platform/` reuses these same original
assets. Its build copies them into ignored local `dist/ui/` files. The Canvas
renderer ports the native standing/laptop pose extraction and registered eye
patches. No additional third-party character artwork is included for Windows.

## Default robot

`desktop/Resources/PipSpriteSheet.png` is an original AI-generated mascot made
with OpenAI's built-in image generation tool on October 13, 2026. It is not an
official OpenAI, ChatGPT, or Codex character and contains no provider branding.
The old `CodexSpriteSheet.webp` is excluded from Git and is not packaged by
the new build. No third-party artwork license is asserted for that old asset.

The new transparent PNG is 1254 × 1254 pixels, four columns by three rows:

1. Idle: standing, breathing, blinking, standing.
2. Working: sitting with a laptop, alternating typing poses.
3. Waiting: alert standing poses for permission requests.

Each row contains four frames. The renderer partitions the image into cells
without resampling the source. Idle has a four-second open-eye hold; working
keeps the first seated pose fixed and pulses an original vector sparkle on the laptop lid. When work ends, Pip returns to idle. Approval waiting uses
the third row and the existing approval badge. Legacy custom sprite sheets are
still supported. Reset to default now restores this original Pip mascot.

Generation prompt: create a production sprite atlas for the original blue robot
reference, preserving its identity, palette, dark screen and cyan eyes; exactly
four equal columns and three equal rows, transparent background, complete
characters inside each cell; row one idle with breathing and a gentle blink,
row two seated with an unbranded silver-blue laptop and alternating typing,
row three standing alert with a head tilt and raised hand; crisp game illustration,
no labels, guides, watermark, text, provider logos, or existing branded mascot.

The reference was also generated for Pip: a cute unbranded blue robot with a
rounded pebble-shaped head, dark face display, cyan oval eyes, a tiny smile,
rounded torso, short arms and feet, transparent background, no cloud-shaped
head or terminal-symbol face. No existing branded mascot image was supplied.

This sheet supplies three states. It does not add separate running, jumping,
waving or failure animations; those non-working states use the idle row.

Pip 0.3.19 fixes sideways movement by holding one seated/laptop frame. The mark's position stays fixed; its brightness animates, and a slow 160 ms eye blink runs about every five seconds without moving the head or laptop. The other laptop poses remain in the source atlas for possible future refinement.

## Built-in character gallery

Pip 0.7.0 adds six characters generated specifically for this project with
OpenAI's built-in image generation tool on October 29, 2026. The source prompts
describe new robots or soft cartoon creatures. No existing Minions image,
provider logo or third-party mascot reference image was supplied or bundled.

| Character | Open-eye artwork | Blink artwork |
| --- | --- | --- |
| Sunny | `desktop/Resources/Characters/Sunny.png` | `SunnyBlink.png` in the same folder |
| Mochi | `desktop/Resources/Characters/Mochi.png` | `MochiBlink.png` in the same folder |
| Boba | `desktop/Resources/Characters/Boba.png` | `BobaBlink.png` in the same folder |
| Lumi | `desktop/Resources/Characters/Lumi.png` | `LumiBlink.png` in the same folder |
| Mallow | `desktop/Resources/Characters/Mallow.png` | `MallowBlink.png` in the same folder |
| Sprout | `desktop/Resources/Characters/Sprout.png` | `SproutBlink.png` in the same folder |

Sunny, Mochi and Boba are the yellow, mint and lilac robot concepts. Lumi is a
peach creature with coral glasses; Mallow is a pink creature in a turquoise
hoodie; Sprout is an aqua creature in a mustard hoodie. Concept references and
the generation prompts are kept under [`design/characters/`](design/characters/).
The PNGs retain their transparent alpha backgrounds and are bundled for offline
use.

The gallery artwork uses two poses per source image: standing and seated with a
laptop. Catalog metadata in `desktop/CreatureCharacters.swift` defines their
pose crops and eye regions. The renderer keeps the chosen body and laptop pose
fixed and uses only the matching closed-eye regions for a slow blink; waiting
requests add Pip's attention badge. These catalog assets are separate from the
default robot's four-column sprite sheet and the custom-sheet import format.

The gallery retains the original Pip robot as the default. Changing a built-in
choice saves its catalog identifier outside the app bundle; resetting restores
the default without deleting imported source images. See
[RELEASE_CHECKS.md](RELEASE_CHECKS.md) for completed asset, renderer and live
Appearance verification. Generation alone is not an animation verification.

## Fluffy character atlases

Native Pip 0.7.2 and Pip Source 0.7.2-alpha.2 bundle six original fluffy
characters generated with the built-in image generation tool on October 30, 2026.
Together with the earlier six and Default Pip, the gallery has thirteen choices:

| Character | Canonical resource in `desktop/Resources/Characters/` |
| --- | --- |
| Peach Puff | `PeachPuff.png` |
| Lavender Mochi | `LavenderMochi.png` |
| Mint Bean | `MintBean.png` |
| Nimbo | `Nimbo.png` |
| Chai | `Chai.png` |
| Plumo | `Plumo.png` |

Each is a transparent 1254 × 1254 atlas with four columns and three rows: idle,
seated laptop work and attentive waiting. The supplied frames provide the eyes
and laptop animation; the renderer does not paint robot-specific overlays onto
these characters. Idle blinks once per 4.74-second cycle, working once per
5.23-second typing cycle, and waiting once per 4.33-second cycle. There is no
walking transform. The original robot and the earlier six characters retain
their existing rendering paths.

`FluffyLayouts.json` stores the per-frame source crops and shared character
canvas used by both renderers. Crops are measured from the main connected alpha
component with a two-pixel fringe. Each frame uses a constant scale, horizontal
center and bottom baseline so generated placement differences do not make it
slide or jump between states. Lavender Mochi and Mint Bean were regenerated
with more transparent clearance to avoid clipping ears or feet. The measurement
script under `design/characters/` rejects main anatomy touching cell boundaries.

The new source prompts and SHA-256 asset hashes are recorded in
[`fluffy-generation-prompts.json`](design/characters/fluffy-generation-prompts.json),
with the two spacing edits in
[`fluffy-margin-correction-prompts.json`](design/characters/fluffy-margin-correction-prompts.json).
The user's Dots reference supplied a general fluffy character direction. The
bundled characters use original shapes, palettes and faces; no downloaded
ChatGPT Dots art, logo or sprite sheet is included. The generator reused only
our own Peach Puff, Lavender Mochi and Mint Bean concepts to preserve their
identities while creating their animation frames.

## Installer background

The revised macOS disk image background is drawn from original shapes and text
by `scripts/InstallerBackground.swift`. It includes both the copy and first-open
steps. Earlier 0.4.1 disk images used dmgbuild 1.6.7's MIT-licensed `builtin-arrow`
artwork; its notice remains included in
`Pip.app/Contents/Resources/Licenses/Installer artwork.txt` for those app bundles.

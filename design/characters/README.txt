Pip's twelve built-in companion designs

Sunny: yellow robot. Mochi: mint robot. Boba: lavender robot.
Lumi: peach creature. Mallow: pink creature. Sprout: aqua creature.

Peach Puff: peach fluff and a cream-tipped antenna.
Lavender Mochi: lavender fluff, floppy ears and a playful tuft.
Mint Bean: mint bean shape, cream feet and a cheerful face.
Nimbo: a soft blue abstract cloud cushion.
Chai: a cinnamon oval puff with a cream curl.
Plumo: a berry-purple rounded lozenge.

The transparent source PNGs are in desktop/Resources/Characters. The original six open
image contains a standing pose and a seated laptop pose. The matching Blink
image supplies closed-eye artwork. CreatureCharacters.swift isolates each pose
and overlays only registered eye patches during a slow blink, keeping the body
and laptop stationary. The original Pip robot remains the default.

The new six use 1254 x 1254, four-column x three-row animation atlases, with
idle, laptop work and waiting rows. Their original generated pixels are kept
in canonical PNG files. FluffyLayouts.json defines validated per-frame crops
and one shared canvas per character. Both apps center and bottom-anchor those
crops at a constant scale, avoiding generated row/column placement drift.
No robot-specific eye or sparkle overlays are applied to these sheets.

Regenerate bounds from the project root after replacing a fluffy atlas:
  swift -O -module-cache-path .build/module-cache design/characters/measure_fluffy_layouts.swift
The measurement finds the largest connected alpha component per cell, retains
a two-pixel fringe, and rejects main anatomy clipped by a cell boundary.
The final Lavender Mochi and Mint Bean sheets were regenerated with more room
around their ears, feet and tuft before measurement.

Artwork was generated with the built-in image_gen tool. Exact generation and
blink-edit prompts for the original six are in generation-prompts.json. The
new six prompts and asset SHA-256 hashes are in fluffy-generation-prompts.json;
the two margin-correction edits are in fluffy-margin-correction-prompts.json.
The user's ChatGPT Dots image provided a general fuzzy character direction;
no downloaded Dots artwork, logo or sprite sheet is bundled.
No branded Minion character
or third-party mascot image is bundled. These files document asset provenance.

Earlier concept copies remain locally under .build/character-concepts-initial;
the published sources use the canonical resource files above.

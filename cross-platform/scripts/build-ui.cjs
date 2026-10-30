const fs = require('node:fs');
const path = require('node:path');
const esbuild = require('esbuild');
const output = path.join(__dirname, '../dist/ui');
fs.mkdirSync(output, { recursive: true });
for (const name of ['index.html', 'style.css']) fs.copyFileSync(path.join(__dirname, '../ui', name), path.join(output, name));
fs.copyFileSync(path.join(__dirname, '../../desktop/Resources/PipSpriteSheet.png'), path.join(output, 'robot.png'));
const characters = path.join(output, 'characters');
fs.mkdirSync(characters, { recursive: true });
for (const name of ['Sunny', 'Mochi', 'Boba', 'Lumi', 'Mallow', 'Sprout']) {
  for (const suffix of ['', 'Blink']) {
    const filename = `${name}${suffix}.png`;
    fs.copyFileSync(path.join(__dirname, '../../desktop/Resources/Characters', filename), path.join(characters, filename));
  }
}
for (const name of ['PeachPuff', 'LavenderMochi', 'MintBean', 'Nimbo', 'Chai', 'Plumo']) {
  fs.copyFileSync(path.join(__dirname, '../../desktop/Resources/Characters', `${name}.png`), path.join(characters, `${name}.png`));
}
const layoutFile = path.join(__dirname, '../../desktop/Resources/Characters/FluffyLayouts.json');
const layouts = JSON.parse(fs.readFileSync(layoutFile, 'utf8'));
fs.copyFileSync(layoutFile, path.join(characters, 'FluffyLayouts.json'));
esbuild.buildSync({ entryPoints: [path.join(__dirname, '../src/renderer.ts')], bundle: true, platform: 'browser', format: 'iife',
  banner: { js: `const __PIP_FLUFFY_LAYOUTS__ = ${JSON.stringify(layouts)};` }, outfile: path.join(output, 'renderer.js') });

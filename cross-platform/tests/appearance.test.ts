import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { AppearanceStore, BUILT_INS } from '../src/appearance';
import { characterChoices } from '../src/characters';
import { write } from '../src/mailbox';

test('all thirteen Appearance choices persist and default remains available after changing characters', async () => {
  assert.deepEqual(BUILT_INS, characterChoices.map(choice => choice.id));
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-appearance-'));
  try {
    for (const selection of [...BUILT_INS, 'default'] as const) {
      const store = new AppearanceStore(root, () => undefined);
      await store.select(selection);
      const reopened = new AppearanceStore(root, () => undefined); await reopened.load();
      assert.deepEqual(reopened.current(), { selection });
    }
    const store = new AppearanceStore(root, () => undefined);
    await assert.rejects(store.select('../other'), /Unknown/);
    assert.deepEqual(store.current(), { selection: 'default' });
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
test('custom images persist, corrupt profiles fall back, and sheet dimensions are checked', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-custom-'));
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==', 'base64');
  try {
    const file = path.join(root, 'character.png'); await fs.writeFile(file, png);
    const store = new AppearanceStore(root, () => ({ width: 1, height: 1 }));
    await store.importFile(file, 'still', 'My character');
    const reopened = new AppearanceStore(root, () => ({ width: 1, height: 1 })); await reopened.load();
    assert.equal(reopened.current().selection, 'custom');
    assert.equal(reopened.current().custom?.name, 'My character');
    await reopened.select('peach-puff');
    const builtIn = new AppearanceStore(root, () => undefined); await builtIn.load();
    assert.deepEqual(builtIn.current(), { selection: 'peach-puff' });
    await builtIn.select('default'); await reopened.load();
    assert.deepEqual(reopened.current(), { selection: 'default' });
    await assert.rejects(store.importFile(file, 'sprite', 'Invalid sheet'), /4 × 3/);
    await write(root, 'appearance.json', { version: 1, selection: 'custom', custom: { kind: 'still', mime: 'text/html', bytes: png.toString('base64'), name: 'Wrong type' } });
    await reopened.load(); assert.deepEqual(reopened.current(), { selection: 'default' });
    const linked = path.join(root, 'linked.png'); await fs.symlink(file, linked);
    await assert.rejects(store.importFile(linked, 'still', 'Linked'), /regular/);
    const oversized = Buffer.from(png); oversized.writeUInt32BE(100_000, 16);
    await fs.writeFile(file, oversized);
    let decoded = false;
    const guarded = new AppearanceStore(root, () => { decoded = true; return { width: 100_000, height: 1 }; });
    await assert.rejects(guarded.importFile(file, 'still', 'Oversized pixels'), /4096/);
    assert.equal(decoded, false, 'Oversized declared dimensions must be rejected before decoding');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

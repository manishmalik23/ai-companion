import test from 'node:test';
import assert from 'node:assert/strict';
import { position, contains, validRegions } from '../src/drag';
test('drag uses a stable screen-space offset across monitors and negative coordinates', () => {
  assert.deepEqual(position({ x: 100, y: 200 }, { x: 230, y: 530 }, { x: 730, y: 430 }), { x: 600, y: 100 });
  assert.deepEqual(position({ x: 100, y: 200 }, { x: 230, y: 530 }, { x: -300, y: -100 }), { x: -430, y: -430 });
});
test('only bounded finite visible UI regions accept clicks', () => {
  const pet = { x: 108, y: 309, width: 144, height: 156 };
  assert.equal(contains(pet, { x: 150, y: 350 }), true);
  assert.equal(contains(pet, { x: 0, y: 0 }), false);
  assert.equal(validRegions([pet]), true);
  assert.equal(validRegions([{ ...pet, x: Number.NaN }]), false);
  assert.equal(validRegions([{ ...pet, width: 1000 }]), false);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { SharedRefresh } from '../src/refresh';

function deferred(): { promise: Promise<boolean>; resolve: (value: boolean) => void } {
  let resolve!: (value: boolean) => void;
  const promise = new Promise<boolean>(done => { resolve = done; });
  return { promise, resolve };
}

test('manual refresh shares the running timer result and changes coalesce into one later write', async () => {
  const first = deferred(), second = deferred();
  let writes = 0;
  const refresh = new SharedRefresh(() => {
    writes += 1;
    return writes === 1 ? first.promise : second.promise;
  });
  const timer = refresh.request();
  await Promise.resolve();
  assert.equal(writes, 1);
  const manual = refresh.request();
  const workspaceChange = refresh.request();
  assert.equal(manual, timer);
  assert.equal(workspaceChange, timer);
  first.resolve(true);
  assert.deepEqual(await Promise.all([timer, manual, workspaceChange]), [true, true, true]);
  assert.equal(writes, 2);
  second.resolve(true);
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(writes, 2);
  refresh.dispose();
});

test('a failed refresh releases the in-flight result for a later successful retry', async () => {
  let writes = 0;
  const refresh = new SharedRefresh(async () => {
    writes += 1;
    if (writes === 1) throw new Error('write failed');
    return true;
  });
  await assert.rejects(refresh.request(), /write failed/);
  assert.equal(await refresh.request(), true);
  assert.equal(writes, 2);
  refresh.dispose();
});

test('disposal prevents queued writes and later refreshes without canceling a waiting caller', async () => {
  const write = deferred();
  let writes = 0;
  const refresh = new SharedRefresh(() => { writes += 1; return write.promise; });
  const active = refresh.request();
  await Promise.resolve();
  assert.equal(refresh.request(), active);
  refresh.dispose();
  write.resolve(true);
  assert.equal(await active, true);
  assert.equal(await refresh.request(), false);
  await Promise.resolve();
  assert.equal(writes, 1);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { codexCapability, CodexNavigationHost, openCodexSession, parseCodexRequest,
  SUPPORTED_CODEX_VERSION, supportsCodexVersion, validateCodexLease } from '../src/codex';
import { EXTENSION_ID, serializeSessionURI, SessionURILike, validateResolvedRoutes } from '../src/protocol';

const KEY = '11f16f2b-98b5-416c-8f15-700df828a81b';
const SESSION = '38f4f440-e050-460f-a9d0-84274d9e9cce';
const BASE = `vscode://${EXTENSION_ID}/codex?windowId=7`;
const REQUEST = `${BASE}&windowKey=${KEY}&sessionId=${SESSION}`;
const TARGET = `vscode://openai.chatgpt/local/${SESSION}?windowId=7`;
const ROUTES = validateResolvedRoutes('vscode://anthropic.claude-code/open?windowId=7',
  `vscode://${EXTENSION_ID}/terminal?windowId=7`);

function uri(value: string): SessionURILike {
  const url = new URL(value);
  return { scheme: url.protocol.slice(0, -1), authority: value.match(/^[^:]+:\/\/([^/?#]+)/)?.[1] ?? '', path: url.pathname,
    query: url.search.slice(1), fragment: url.hash.slice(1),
    toString(skipEncoding = false): string {
      return `${this.scheme}://${this.authority}${this.path}${this.query ? '?' + (skipEncoding ? this.query : encodeURIComponent(this.query)) : ''}${this.fragment ? '#' + this.fragment : ''}`;
    } };
}

function host(overrides: Partial<CodexNavigationHost> = {}) {
  const resolved: string[] = [], opened: string[] = [];
  const api: CodexNavigationHost = {
    extensionVersion: () => SUPPORTED_CODEX_VERSION,
    resolveURI: async value => { resolved.push(value); return uri(`${value}?windowId=7`); },
    openURI: async value => { opened.push(value); return true; },
    isCurrent: () => true, ...overrides
  };
  return { api, resolved, opened };
}

test('Codex capability is optional and advertised only for the exact inspected version and window', () => {
  assert.equal(supportsCodexVersion(SUPPORTED_CODEX_VERSION), true);
  for (const version of [undefined, null, 26, '', '26.1021.22028', '26.1021.22027-beta', '27.0.0']) {
    assert.equal(supportsCodexVersion(version), false);
    assert.equal(codexCapability(version, BASE, ROUTES), undefined);
  }
  assert.deepEqual(codexCapability(SUPPORTED_CODEX_VERSION, BASE, ROUTES), {
    codexSessionURL: BASE, codexExtensionVersion: SUPPORTED_CODEX_VERSION
  });
  validateCodexLease({}, ROUTES);
  for (const capability of [{ codexSessionURL: BASE }, { codexExtensionVersion: SUPPORTED_CODEX_VERSION },
      { codexSessionURL: BASE, codexExtensionVersion: 'new-version' }]) {
    assert.throws(() => validateCodexLease(capability, ROUTES));
  }
  for (const value of [BASE.replace('=7', '=8'), `${BASE}&prompt=hello`, `${BASE}&windowId=7`,
      BASE.replace('/codex?', '/terminal?'), BASE.replace('vscode:', 'vscode-insiders:')]) {
    assert.throws(() => codexCapability(SUPPORTED_CODEX_VERSION, value, ROUTES));
  }
});

test('Codex request binds the exact window, window key, and canonical local UUID only', () => {
  assert.equal(parseCodexRequest(REQUEST, KEY, ROUTES), SESSION);
  assert.equal(parseCodexRequest(REQUEST.replace(SESSION, SESSION.toUpperCase()), KEY, ROUTES), SESSION);
  for (const value of [REQUEST.replace('windowId=7', 'windowId=8'), REQUEST.replace('windowId=7&', ''),
      REQUEST.replace(KEY, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), REQUEST.replace(SESSION, 'new'),
      REQUEST.replace(SESSION, '../new'), REQUEST.replace(SESSION, SESSION + '/extra'),
      `${REQUEST}&prompt=hello`, `${REQUEST}&command=chatgpt.newChat`, `${REQUEST}&hostId=remote`,
      `${REQUEST}&sessionId=${SESSION}`, `${REQUEST}&windowKey=${KEY}`, `${REQUEST}&windowId=7`,
      REQUEST.replace('/codex?', '/terminal?'), `${REQUEST}#fragment`, REQUEST.replace('//', '//user@'),
      REQUEST.replace(EXTENSION_ID, `${EXTENSION_ID}:44`), REQUEST.replace('vscode:', 'https:')]) {
    assert.equal(parseCodexRequest(value, KEY, ROUTES), undefined);
  }
});

test('the adapter resolves the complete existing-thread URI in its own window and preserves query delimiters', async () => {
  const fake = host();
  assert.equal(await openCodexSession(REQUEST, KEY, ROUTES, fake.api), 'opened');
  assert.deepEqual(fake.resolved, [`vscode://openai.chatgpt/local/${SESSION}`]);
  assert.deepEqual(fake.opened, [TARGET]);
  assert.equal(new URL(fake.opened[0]).searchParams.get('windowId'), '7');
  assert.equal(serializeSessionURI(uri(BASE)), BASE);
});

test('invalid requests and unsupported versions never resolve or open a URI', async () => {
  const invalid = host();
  assert.equal(await openCodexSession(`${REQUEST}&prompt=hello`, KEY, ROUTES, invalid.api), 'invalid_request');
  assert.deepEqual(invalid.resolved, []); assert.deepEqual(invalid.opened, []);
  const unknown = host({ extensionVersion: () => '26.1021.22028' });
  assert.equal(await openCodexSession(REQUEST, KEY, ROUTES, unknown.api), 'unsupported_version');
  assert.deepEqual(unknown.resolved, []); assert.deepEqual(unknown.opened, []);
});

test('generic, wrong-window, or expanded Codex routes are rejected without opening', async () => {
  for (const target of [TARGET.replace('=7', '=8'), TARGET.split('?')[0], `${TARGET}&prompt=hello`,
      `${TARGET}&hostId=remote`, `${TARGET}&windowId=7`, `${TARGET}#fragment`, TARGET.replace('//', '//user@'),
      TARGET.replace('openai.chatgpt', 'attacker.example'), TARGET.replace(SESSION, 'new'),
      TARGET.replace('/local/', '/remote/'), TARGET.replace(SESSION, SESSION + '/extra'),
      TARGET.replace('vscode:', 'vscode-insiders:'), TARGET.replace('vscode:', 'https:')]) {
    const fake = host({ resolveURI: async () => uri(target) });
    assert.equal(await openCodexSession(REQUEST, KEY, ROUTES, fake.api), 'unavailable_window_route', target);
    assert.deepEqual(fake.opened, []);
  }
});

test('an extension update or superseded click during resolution never opens a stale route', async () => {
  let version = SUPPORTED_CODEX_VERSION;
  const updated = host({ extensionVersion: () => version,
    resolveURI: async () => { version = '26.1021.22028'; return uri(TARGET); } });
  assert.equal(await openCodexSession(REQUEST, KEY, ROUTES, updated.api), 'unsupported_version');
  assert.deepEqual(updated.opened, []);
  let current = true;
  const cancelled = host({ isCurrent: () => current,
    resolveURI: async () => { current = false; return uri(TARGET); } });
  assert.equal(await openCodexSession(REQUEST, KEY, ROUTES, cancelled.api), 'cancelled');
  assert.deepEqual(cancelled.opened, []);
});

test('URI resolution and opening failures return static diagnostic categories', async () => {
  const failedResolution = host({ resolveURI: async () => { throw new Error('private resolver text'); } });
  assert.equal(await openCodexSession(REQUEST, KEY, ROUTES, failedResolution.api), 'unavailable_window_route');
  assert.deepEqual(failedResolution.opened, []);
  for (const openURI of [async () => false, async () => { throw new Error('private open text'); }]) {
    assert.equal(await openCodexSession(REQUEST, KEY, ROUTES, host({ openURI }).api), 'open_failed');
  }
});

import type { BrowserWindow } from 'electron';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import { handle } from './hook';
import { Mailbox, read } from './mailbox';
import { animatedCharacterChoices, characterChoices } from './characters';

/** Real Electron/IPC/Node-hook round trips, all in an isolated disposable runtime. */
export async function smoke(window: BrowserWindow, mailbox: Mailbox, poll: () => Promise<void>): Promise<void> {
  const output = path.resolve('artifacts'); await fs.mkdir(output, { recursive: true });
  const check = async (code: string) => {
    try { return await window.webContents.executeJavaScript(code); }
    catch (error) { throw new Error(`Renderer check failed: ${code.slice(0, 240)} (${(error as Error).message})`); }
  };
  const pause = () => new Promise(resolve => setTimeout(resolve, 40));
  async function until(code: string, message: string, attempts = 125): Promise<void> {
    for (let i = 0; i < attempts; i++) { await poll(); await pause(); if (await check(code)) return; }
    throw new Error(message);
  }
  const click = (id: string) => check(`document.getElementById(${JSON.stringify(id)}).click()`);
  const capture = async (name: string) => {
    // Computed styles update before the compositor and the 50 ms character painter.
    await check('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 70))))');
    await fs.writeFile(path.join(output, name + '.png'), (await window.webContents.capturePage()).toPNG());
  };
  await until('typeof window.pip?.answer === "function"', 'Preload did not initialize');
  assert.equal((await read(mailbox.root, 'telemetry-health.json') as { status: string }).status, 'listening');
  assert.equal(await check('typeof require'), 'undefined'); assert.equal(await check('typeof process'), 'undefined');
  assert.equal(await check('document.querySelector("meta[http-equiv=Content-Security-Policy]").content.includes("connect-src \'none\'")'), true);
  assert.deepEqual(await check('window.pip.openChat("unexpected")'), { error: 'Unknown chat app.' });
  assert.deepEqual(await check('window.pip.selectCharacter("../unknown")'), { error: 'Unknown character.' });
  for (const provider of ['claude', 'chatgpt']) {
    await click(provider); await until('document.getElementById("launch-status").textContent.includes("disabled during verification")', 'Provider launch must stay disabled in smoke');
  }
  await check('document.getElementById("launch-status").textContent = ""');
  assert.equal(await check('getComputedStyle(document.getElementById("pet")).getPropertyValue("-webkit-app-region")'), 'no-drag');
  await check("document.getElementById('pet').dispatchEvent(new PointerEvent('pointerdown',{button:0,pointerId:1,bubbles:true})); document.getElementById('pet').dispatchEvent(new PointerEvent('pointerup',{button:0,pointerId:1,bubbles:true}))");

  await click('appearance-open');
  await until('document.querySelectorAll("#appearance-grid canvas[data-loaded=true]").length === 13', 'Thirteen character thumbnails did not load', 500);
  assert.equal(await check('document.querySelectorAll("#appearance-grid [role=radio]").length'),13);
  for (const dark of [false, true]) {
    await check(`document.documentElement.classList.toggle('dark',${dark})`); await capture(`appearance-${dark ? 'dark' : 'light'}`);
  }
  for (const {id} of characterChoices.filter(choice=>choice.id!=='default')) {
    await click('character-' + id);
    await until(`document.getElementById('appearance-preview').dataset.character === '${id}'`, 'Character preview did not load ' + id);
    assert.equal(await check(`document.getElementById('character-${id}').getAttribute('aria-checked')`),'true');
    for (const mood of ['idle','working','waiting']) {
      await click('preview-'+mood);
      assert.equal(await check(`document.getElementById('preview-${mood}').getAttribute('aria-pressed')`),'true');
      await check('document.querySelector(".character-preview").scrollIntoView({block:"center"}); new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
      assert.equal(await check('(() => { const preview = document.querySelector(".character-preview").getBoundingClientRect(), scroll = document.querySelector(".appearance-scroll"), viewport = scroll.getBoundingClientRect(); return preview.top >= viewport.top - 1 && preview.bottom <= viewport.bottom + 1 && preview.left >= viewport.left - 1 && preview.right <= viewport.left + scroll.clientWidth + 1; })()'),true,`The ${id} ${mood} preview and state controls must be fully visible`);
      await capture('character-'+id+'-'+mood);
    }
    await click('apply-character');
    await until(`document.getElementById('robot').dataset.character === '${id}'`, 'Character did not apply ' + id);
    assert.equal((await read(mailbox.root, 'appearance.json') as { selection: string }).selection, id);
    if(animatedCharacterChoices.some(choice=>choice.id===id)){
      await click('reset-character');
      await until('document.getElementById("robot").dataset.character === "default"', 'Default reset did not apply after '+id);
      assert.equal((await read(mailbox.root,'appearance.json') as {selection:string}).selection,'default');
    }
  }
  await click('reset-character'); await until('document.getElementById("robot").dataset.character === "default"', 'Default reset did not apply');
  window.setSize(420, 600);
  await until('window.innerHeight === 600', 'Small display fixture did not resize');
  assert.equal(await check('document.getElementById("appearance-panel").getBoundingClientRect().top >= 0 && document.getElementById("handle").getBoundingClientRect().bottom <= innerHeight'), true);
  assert.equal(await check('document.querySelector(".appearance-scroll").scrollHeight > document.querySelector(".appearance-scroll").clientHeight'),true);
  assert.equal(await check('document.querySelector(".appearance-scroll").scrollWidth <= document.querySelector(".appearance-scroll").clientWidth'),true);
  await check('document.getElementById("character-plumo").scrollIntoView({block:"nearest"})');
  assert.equal(await check('document.getElementById("character-plumo").getBoundingClientRect().bottom <= document.querySelector(".appearance-scroll").getBoundingClientRect().bottom + 1'),true);
  await check('document.getElementById("quit").scrollIntoView({block:"nearest"})');
  assert.equal(await check('document.getElementById("quit").getBoundingClientRect().bottom <= document.querySelector(".appearance-scroll").getBoundingClientRect().bottom + 1'),true);
  await check('document.querySelector(".appearance-scroll").scrollTop = 0');
  await capture('appearance-small-display'); window.setSize(420, 700);
  await until('window.innerHeight === 700', 'Normal display size did not restore');
  await click('appearance-close');
  assert.equal(await check('document.getElementById("card").hidden'), true);

  for (const decision of ['allow', 'deny'] as const) {
    const event = { hook_event_name: 'PermissionRequest', session_id: `smoke-${decision}`, turn_id: 'smoke-turn',
      tool_name: 'Bash', tool_input: { command: '<img src=x onerror="window.injected=true">', description: 'Show the reason once' } };
    const response = handle(mailbox.root, 'codex', event, 10, true);
    await until('!document.getElementById("card").hidden', 'Permission card did not appear');
    assert.equal(await check('document.getElementById("tool").textContent'), 'Run command');
    assert.equal(await check('document.getElementById("details").textContent.includes("<img src=x")'), true);
    assert.equal(await check('window.injected'), undefined);
    assert.equal(await check('document.getElementById("details").textContent.includes("description")'), true); // Demo reason differs from supplied description.
    const light = await check('getComputedStyle(document.getElementById("card")).backgroundColor');
    await check("document.documentElement.classList.add('dark')");
    assert.notEqual(light, await check('getComputedStyle(document.getElementById("card")).backgroundColor'));
    await capture('approval-dark-' + decision);
    await check("document.documentElement.classList.remove('dark')"); await capture('approval-' + decision);
    await click(decision);
    const result = await response as { hookSpecificOutput: { decision: { behavior: string } } };
    assert.equal(result.hookSpecificOutput.decision.behavior, decision);
    await until('document.getElementById("card").hidden', 'Resolved permission card did not disappear');
    await handle(mailbox.root, 'codex', { ...event, hook_event_name: 'Stop' });
  }

  const question = 'Which language should this demo use?';
  const event = { hook_event_name: 'PreToolUse', session_id: 'smoke-question', tool_use_id: 'question-one', tool_name: 'AskUserQuestion',
    tool_input: { questions: [{ question, header: 'Language', options: [{ label: 'TypeScript' }, { label: 'Python' }], multiSelect: false }], preserve: 'unchanged' } };
  const response = handle(mailbox.root, 'claude', event, 15, true);
  await until('!document.getElementById("question-form").hidden', 'Question form did not appear');
  await check('document.querySelectorAll("#question-form input").item(2).click()');
  await until('document.activeElement?.id === "other-0"', 'Other field did not receive focus');
  assert.equal(await check('document.getElementById("other-0").getBoundingClientRect().bottom <= document.querySelector(".request-scroll").getBoundingClientRect().bottom + 1'), true);
  await window.webContents.insertText('TypeScript with typed Other text');
  assert.equal(await check('document.getElementById("other-0").value'), 'TypeScript with typed Other text');
  const parallel = { hook_event_name: 'PermissionRequest', session_id: 'smoke-parallel', tool_use_id: 'parallel-one', tool_name: 'Read', tool_input: { file_path: '/demo/example.ts', description: 'Read one demo file' } };
  const parallelResponse = handle(mailbox.root, 'claude', parallel, 15, true);
  await until('document.getElementById("count").textContent === "2 pending"', 'Concurrent request did not join the queue');
  assert.equal(await check('document.activeElement?.id'), 'other-0');
  assert.equal(await check('document.getElementById("other-0").value'), 'TypeScript with typed Other text');
  await click('next'); assert.equal(await check('document.getElementById("tool").textContent'), 'Read file');
  await click('previous');
  assert.equal(await check('document.getElementById("other-0").value'), 'TypeScript with typed Other text');
  await capture('question-other'); await click('submit-answer');
  const answered = await response as { hookSpecificOutput: { updatedInput: { answers: Record<string, string>; preserve: string } } };
  assert.equal(answered.hookSpecificOutput.updatedInput.answers[question], 'TypeScript with typed Other text');
  assert.equal(answered.hookSpecificOutput.updatedInput.preserve, 'unchanged');
  await until('document.getElementById("tool").textContent === "Read file"', 'Remaining queue request disappeared incorrectly');
  await click('deny'); await parallelResponse;
  await handle(mailbox.root, 'claude', { ...event, hook_event_name: 'Stop' });
  await handle(mailbox.root, 'claude', { ...parallel, hook_event_name: 'Stop' });
  await until('document.getElementById("card").hidden', 'Question queue did not clear');

  const deferred = handle(mailbox.root, 'claude', { ...event, session_id: 'smoke-defer', tool_use_id: 'question-defer' }, 10, true);
  await until('!document.getElementById("question-actions").hidden', 'Deferrable question did not appear');
  await click('defer'); assert.equal(await deferred, undefined);
  const notice = { hook_event_name: 'PreToolUse', session_id: 'smoke-notice', tool_use_id: 'notice-one', tool_name: 'request_user_input_async', tool_input: { questions: [{ title: 'Continue in Codex?' }] } };
  await handle(mailbox.root, 'codex', notice, 10, true);
  await until('!document.getElementById("notice-actions").hidden', 'Codex question should be an alert');
  await capture('codex-notice'); await click('dismiss');
  await until('document.getElementById("card").hidden', 'Dismissed notice did not disappear');
  assert.equal((await fs.readdir(path.join(mailbox.root, 'decisions'))).length, 0);

  // Exercise the real main-process loopback receiver, then watch the real renderer queue update.
  const tools = ['toolu_smoke_a', 'toolu_smoke_b'];
  const pending: Promise<unknown>[] = [];
  for (const [index, id] of tools.entries()) {
    const tool = { session_id: 'smoke-external', prompt_id: 'smoke-prompt', tool_use_id: id, tool_name: 'Bash', tool_input: { command: `display-only-${index}`, description: `External request ${index}` } };
    await handle(mailbox.root, 'claude', { ...tool, hook_event_name: 'PreToolUse' });
    pending.push(handle(mailbox.root, 'claude', { ...tool, hook_event_name: 'PermissionRequest' }, 15, true));
  }
  await until('document.getElementById("count").textContent === "2 pending"', 'External-decision requests did not appear');
  const receiver = await read(mailbox.root, 'telemetry.json') as { port: number; token: string };
  const at = Date.now() / 1000, attr = (key: string, value: string) => ({ key, value: { stringValue: value } });
  const data = JSON.stringify({ resourceLogs: [{ resource: { attributes: [attr('service.name', 'claude-code')] }, scopeLogs: [{ scope: { name: 'com.anthropic.claude_code.events' }, logRecords: [{
    timeUnixNano: String(BigInt(Math.round(at * 1000)) * 1_000_000n), body: { stringValue: 'claude_code.tool_decision' },
    attributes: [attr('event.name', 'tool_decision'), attr('event.timestamp', new Date(at * 1000).toISOString()), attr('session.id', 'smoke-external'), attr('prompt.id', 'smoke-prompt'), attr('tool_use_id', tools[0]!), attr('decision', 'accept'), attr('source', 'user_temporary')]
  }] }] }] });
  const status = await new Promise<number>((resolve, reject) => {
    const req = http.request(`http://127.0.0.1:${receiver.port}/v1/logs`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data), 'X-Pip-Token': receiver.token } }, res => { res.resume(); res.on('end', () => resolve(res.statusCode!)); }); req.on('error', reject); req.end(data);
  });
  assert.equal(status, 200); assert.equal(await pending[0], undefined);
  await until('document.getElementById("count").textContent === "1 pending"', 'An acceptance in the source did not clear exactly its own card');
  assert.equal((await mailbox.poll()).working, true);
  await capture('external-decision-remaining'); await click('allow'); await pending[1];
  await handle(mailbox.root, 'claude', { hook_event_name: 'SessionEnd', session_id: 'smoke-external' });
  await until('document.getElementById("card").hidden', 'Final card did not clear');
  console.log('Electron smoke passed: thirteen characters, all new-character apply/reset round trips, idle/working/waiting previews, small-display gallery scrolling, persistence, system themes, literal tool text, approval/denial, typed Other focus, concurrent queue drafts, source defer, Codex notice dismiss, authenticated external decision clearing and renderer isolation. Synthetic events only; no real agent settings changed.');
}

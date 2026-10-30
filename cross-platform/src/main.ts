import { app, BrowserWindow, dialog, ipcMain, Menu, nativeImage, nativeTheme, shell, Tray } from 'electron';
import path from 'node:path';
import * as fs from 'node:fs/promises';
import { mkdtempSync } from 'node:fs';
import os from 'node:os';
import { Mailbox, defaultRuntime, read, write } from './mailbox';
import { position, contains, validRegions, Rect, Point } from './drag';
import { AppearanceStore, BUILT_INS } from './appearance';
import { destination, readSessionLeases } from './navigation';
import { SessionHandoff } from './session-handoff';
import { startTelemetry, TelemetryReceiver } from './telemetry';
import { prepareConnection, applyConnection, restoreConnection } from './connect';

app.setName('Pip Source');
if (process.platform === 'win32') app.setAppUserModelId('dev.local.pip-source');
const smokeMode = process.argv.includes('--smoke');
const userData = smokeMode ? mkdtempSync(path.join(os.tmpdir(), 'pip-source-smoke-ui-')) : path.dirname(defaultRuntime());
app.setPath('userData', userData);
let window: BrowserWindow | undefined, mailbox: Mailbox | undefined, tray: Tray | undefined;
let telemetry: TelemetryReceiver | undefined;
let timer: NodeJS.Timeout | undefined, mouseTimer: NodeJS.Timeout | undefined;
let polling = false, closing = false;

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => window?.showInactive());
  app.whenReady().then(async () => {
    const root = smokeMode ? await fs.mkdtemp(path.join(os.tmpdir(), 'pip-source-smoke-runtime-')) : defaultRuntime();
    mailbox = new Mailbox(root); await mailbox.start();
    const appearance = new AppearanceStore(root, bytes => {
      const image = nativeImage.createFromBuffer(bytes);
      return image.isEmpty() ? undefined : image.getSize();
    });
    await appearance.load();
    let telemetryError: string | undefined;
    try { telemetry = await startTelemetry(root); }
    catch { telemetryError = 'Immediate Claude decision sync is unavailable. Completion hooks still work.'; }
    const { screen } = await import('electron');
    const area = screen.getPrimaryDisplay().workArea;
    const width = 420, height = Math.min(700, area.height);
    let origin = { x: Math.max(area.x, area.x + area.width - width - 20), y: Math.max(area.y, area.y + area.height - height - 20) };
    if (!smokeMode) {
      try {
        const saved = await read(root, 'window-position.json', 512) as Point;
        if (Number.isFinite(saved.x) && Number.isFinite(saved.y) && Math.abs(saved.x) < 100_000 && Math.abs(saved.y) < 100_000) {
          const display = screen.getDisplayNearestPoint(saved).workArea;
          origin = { x: Math.round(Math.max(display.x, Math.min(saved.x, display.x + display.width - width))),
            y: Math.round(Math.max(display.y, Math.min(saved.y, display.y + display.height - height))) };
        }
      } catch { /* A fresh source install uses the primary screen. */ }
    }
    window = new BrowserWindow({ title: 'Pip Source', width, height, ...origin,
      transparent: true, frame: false, resizable: false, hasShadow: false, alwaysOnTop: true,
      skipTaskbar: true, backgroundColor: '#00000000', show: false, focusable: true,
      webPreferences: { preload: path.join(__dirname, 'preload.js'), nodeIntegration: false,
        contextIsolation: true, sandbox: true, webSecurity: true, backgroundThrottling: !smokeMode }
    });
    window.setAlwaysOnTop(true, 'floating');
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    window.webContents.on('will-navigate', event => event.preventDefault());
    window.webContents.on('will-attach-webview', event => event.preventDefault());
    window.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
    window.once('ready-to-show', () => { if (!smokeMode) window?.showInactive(); });
    const sender = (event: Electron.IpcMainInvokeEvent | Electron.IpcMainEvent) =>
      !!window && event.sender === window.webContents && event.senderFrame === window.webContents.mainFrame;
    const failure = (error: unknown) => ({ error: error instanceof Error ? error.message : 'Local action failed.' });
    let uiSignature = '';

    async function chooseApp(provider: 'claude' | 'chatgpt'): Promise<void> {
      if (smokeMode || !window) return;
      const result = await dialog.showOpenDialog(window, { title: `Choose ${provider === 'claude' ? 'Claude' : 'ChatGPT'} desktop app`,
        properties: ['openFile'], filters: [{ name: 'Desktop application', extensions: process.platform === 'win32' ? ['exe'] : ['app'] }] });
      if (result.canceled || result.filePaths.length !== 1) return;
      const target = result.filePaths[0]!, stat = await fs.lstat(target);
      if (!path.isAbsolute(target) || stat.isSymbolicLink() ||
          (process.platform === 'win32' ? !stat.isFile() || path.extname(target).toLowerCase() !== '.exe' : !stat.isDirectory() || path.extname(target) !== '.app')) throw new Error('Choose the installed desktop application.');
      let apps: Record<string, string> = {};
      try { const previous = await read(root, 'desktop-apps.json', 16_384); if (previous && typeof previous === 'object' && !Array.isArray(previous)) apps = previous as Record<string, string>; } catch { /* No configured applications. */ }
      await write(root, 'desktop-apps.json', { ...apps, [provider]: target });
    }
    async function openChat(provider: 'claude' | 'chatgpt'): Promise<void> {
      if (smokeMode) throw new Error('App launching is disabled during verification.');
      const name = provider === 'claude' ? 'Claude' : 'ChatGPT';
      let configured: unknown;
      try { configured = (await read(root, 'desktop-apps.json', 16_384) as Record<string, unknown>)[provider]; } catch { /* Use known macOS Applications folders. */ }
      const targets = typeof configured === 'string' && path.isAbsolute(configured) ? [configured] :
        process.platform === 'darwin' ? ['/Applications', path.join(os.homedir(), 'Applications')].map(folder => path.join(folder, name + '.app')) : [];
      for (const target of targets) {
        try {
          const stat = await fs.lstat(target);
          if (stat.isSymbolicLink() || (process.platform === 'darwin' ? !stat.isDirectory() || !target.endsWith('.app') : !stat.isFile() || path.extname(target).toLowerCase() !== '.exe')) continue;
          const error = await shell.openPath(target); if (error) throw new Error(`Could not open ${name}. Choose its installed app again from Pip's tray menu.`);
          return;
        } catch (error) { if (error instanceof Error && error.message.startsWith('Could not open')) throw error; }
      }
      throw new Error(`${name} is not configured. Use the tray menu to choose its installed desktop app.`);
    }
    ipcMain.handle('pip:open-chat', async (event, provider: unknown) => {
      if (!sender(event) || (provider !== 'claude' && provider !== 'chatgpt')) return { error: 'Unknown chat app.' };
      try { await openChat(provider); return {}; } catch (error) { return failure(error); }
    });
    ipcMain.handle('pip:select-character', async (event, choice: unknown) => {
      if (!sender(event)) return { error: 'Unavailable appearance action.' };
      try {
        if (typeof choice === 'string' && (BUILT_INS as readonly string[]).includes(choice)) await appearance.select(choice);
        else if (choice === 'import-still' || choice === 'import-sprite') {
          if (smokeMode || !window) return { error: 'File selection is disabled during verification.' };
          const selected = await dialog.showOpenDialog(window, { title: choice === 'import-sprite' ? 'Choose a 4 × 3 animated character sheet' : 'Choose a transparent character image',
            properties: ['openFile'], filters: [{ name: 'Character image', extensions: ['png', 'webp'] }] });
          if (!selected.canceled && selected.filePaths.length === 1) {
            const file = selected.filePaths[0]!; await appearance.importFile(file, choice === 'import-sprite' ? 'sprite' : 'still', path.basename(file));
          }
        } else return { error: 'Unknown character.' };
        uiSignature = ''; await poll(); return {};
      } catch (error) { return failure(error); }
    });
    ipcMain.handle('pip:decision', async (event, id: unknown, decision: unknown) => {
      if (!sender(event) || typeof id !== 'string' || (decision !== 'allow' && decision !== 'deny')) return { error: 'Invalid decision.' };
      try { await mailbox!.decide(id, decision); await poll(); return {}; } catch (error) { return failure(error); }
    });
    ipcMain.handle('pip:answer', async (event, id: unknown, answers: unknown) => {
      if (!sender(event) || typeof id !== 'string') return { error: 'Invalid answer.' };
      try { await mailbox!.answer(id, answers as Record<string, string>); await poll(); return {}; } catch (error) { return failure(error); }
    });
    ipcMain.handle('pip:defer', async (event, id: unknown) => {
      if (!sender(event) || typeof id !== 'string') return { error: 'Invalid request.' };
      try { await mailbox!.defer(id); await poll(); return {}; } catch (error) { return failure(error); }
    });
    ipcMain.handle('pip:dismiss', async (event, id: unknown) => {
      if (!sender(event) || typeof id !== 'string') return { error: 'Invalid alert.' };
      try { await mailbox!.dismiss(id); await poll(); return {}; } catch (error) { return failure(error); }
    });
    const handoff = new SessionHandoff({
      pending: async () => (await mailbox!.poll()).requests,
      destination: async request => destination(request, await readSessionLeases({ fresh: true })),
      navigate: target => shell.openExternal(target),
      defer: (id,snapshot) => mailbox!.defer(id,snapshot),
      dismiss: (id,snapshot) => mailbox!.dismiss(id,snapshot)
    });
    ipcMain.handle('pip:open-session', async (event, id: unknown, snapshot: unknown) => {
      if (!sender(event) || typeof id !== 'string') return { error: 'Invalid session.' };
      if (smokeMode) return { error: 'Session launching is disabled during verification.' };
      try {
        await handoff.open(id,snapshot); await poll(); return {};
      } catch (error) { return failure(error); }
    });
    let regions: Rect[] = [{ x: 138, y: height - 198, width: 144, height: 156 }, { x: 70, y: height - 40, width: 280, height: 26 }];
    let drag: { origin: Point; start: Point; began: number } | undefined, ignored = false;
    ipcMain.on('pip:regions', (event, value: unknown) => { if (sender(event) && validRegions(value)) regions = value; });
    ipcMain.on('pip:drag-start', event => {
      if (!sender(event) || !window) return;
      const bounds = window.getBounds();
      drag = { origin: { x: bounds.x, y: bounds.y }, start: screen.getCursorScreenPoint(), began: Date.now() };
      ignored = false; window.setIgnoreMouseEvents(false);
    });
    ipcMain.on('pip:drag-end', event => {
      if (!sender(event)) return; drag = undefined;
      if (!smokeMode && window) { const { x, y } = window.getBounds(); void write(root, 'window-position.json', { x, y }).catch(() => undefined); }
    });
    window.on('blur', () => { drag = undefined; });
    if (!smokeMode) mouseTimer = setInterval(() => {
      if (!window || window.isDestroyed()) return;
      const cursor = screen.getCursorScreenPoint();
      if (drag && Date.now() - drag.began < 30_000) { const next = position(drag.origin, drag.start, cursor); window.setPosition(next.x, next.y, false); return; }
      drag = undefined;
      const bounds = window.getBounds(), relative = { x: cursor.x - bounds.x, y: cursor.y - bounds.y };
      const nextIgnored = !regions.some(rect => contains(rect, relative));
      if (ignored !== nextIgnored) { ignored = nextIgnored; window.setIgnoreMouseEvents(ignored, { forward: true }); }
    }, 16);
    ipcMain.on('pip:quit', event => { if (sender(event)) app.quit(); });
    async function poll(): Promise<void> {
      if (polling || closing) return;
      polling = true;
      try {
        const state = await mailbox!.poll(), leases = state.requests.length ? await readSessionLeases() : [];
        const requests = state.requests.map(request => ({ ...request, navigation: { available: !!destination(request, leases) } }));
        const signature = JSON.stringify({ ...state, requests, dark: nativeTheme.shouldUseDarkColors, appearanceRevision: appearance.revision, telemetryError });
        if (signature !== uiSignature) {
          uiSignature = signature;
          window?.webContents.send('pip:state', { ...state, requests, dark: nativeTheme.shouldUseDarkColors,
            appearance: appearance.current(), connectionStatus: telemetryError });
        }
      } catch { window?.webContents.send('pip:state', { requests: [], working: false, error: 'Local connection unavailable.', dark: nativeTheme.shouldUseDarkColors, appearance: appearance.current() }); uiSignature = ''; }
      finally { polling = false; }
    }
    const options = () => ({ nodePath: process.env.PIP_NODE_EXECUTABLE });
    async function connect(): Promise<void> {
      if (smokeMode || !window) return;
      try {
        const plan = await prepareConnection(os.homedir(), root, options());
        const summary = plan.targets.map(t => `${t.source === 'claude' ? 'Claude Code' : 'Codex'}: ${t.added} Pip hooks, replacing ${t.removed} previous Pip hooks.`).join('\n');
        const answer = await dialog.showMessageBox(window, { type: 'question', title: 'Connect Pip Source',
          message: 'Connect local agent hooks to this source version?', detail: `${summary}\n\nUnrelated settings stay in place. Pip saves backups. Review Codex /hooks afterward and reload Claude after active work finishes.`,
          buttons: ['Cancel', 'Connect'], defaultId: 0, cancelId: 0 });
        if (answer.response !== 1) return;
        await applyConnection(os.homedir(), root, options());
        await dialog.showMessageBox(window, { type: 'info', message: 'Hooks connected to Pip Source', detail: 'Review and trust Pip in Codex /hooks. Reload or restart Claude after active work finishes.' });
      } catch (error) { await dialog.showMessageBox(window, { type: 'error', message: 'Could not connect agent hooks', detail: failure(error).error }); }
    }
    async function restore(): Promise<void> {
      if (smokeMode || !window) return;
      const answer = await dialog.showMessageBox(window, { type: 'question', message: 'Restore the agent settings saved before connecting Pip Source?',
        detail: 'Finish current agent work first. Restore refuses if settings changed afterward.', buttons: ['Cancel', 'Restore'], defaultId: 0, cancelId: 0 });
      if (answer.response !== 1) return;
      try { await restoreConnection(os.homedir(), root, options()); await dialog.showMessageBox(window, { message: 'Previous settings restored. Review/reload your agents after active work.' }); }
      catch (error) { await dialog.showMessageBox(window, { type: 'error', message: 'Could not restore settings', detail: failure(error).error }); }
    }
    const menu = Menu.buildFromTemplate([
      { label: 'Show Pip Source', click: () => window?.showInactive() },
      { label: telemetryError || 'Claude decision receiver ready', enabled: false },
      { label: 'Appearance…', click: () => { window?.show(); window?.webContents.send('pip:show-appearance'); } },
      { label: 'Agent connections…', click: () => { void connect(); } },
      { label: 'Restore previous agent settings…', click: () => { void restore(); } },
      { type: 'separator' },
      { label: 'Open Claude', click: () => { void openChat('claude').catch(error => dialog.showErrorBox('Claude', failure(error).error)); } },
      { label: 'Open ChatGPT', click: () => { void openChat('chatgpt').catch(error => dialog.showErrorBox('ChatGPT', failure(error).error)); } },
      ...(['claude', 'chatgpt'] as const).map(provider => ({ label: `Choose ${provider === 'claude' ? 'Claude' : 'ChatGPT'} desktop app…`, click: () => { void chooseApp(provider).catch(error => dialog.showErrorBox('Desktop application', failure(error).error)); } })),
      { type: 'separator' }, { label: 'Quit Pip Source', role: 'quit' }
    ]);
    Menu.setApplicationMenu(Menu.buildFromTemplate([{ label: 'Pip Source', submenu: menu }]));
    if (!smokeMode) {
      const image = nativeImage.createFromPath(path.join(__dirname, '../ui/robot.png')), size = image.getSize();
      const icon = image.crop({ x: 0, y: 0, width: Math.floor(size.width / 4), height: Math.floor(size.height / 3) }).resize({ width: 20, height: 20 });
      tray = new Tray(icon); tray.setToolTip('Pip Source'); tray.setContextMenu(menu); tray.on('click', () => window?.showInactive());
    }
    window.webContents.on('did-finish-load', () => { uiSignature = ''; void poll(); });
    await window.loadFile(path.join(__dirname, '../ui/index.html'));
    if (!smokeMode) timer = setInterval(() => void poll(), 200);
    app.dock?.hide();
    if (smokeMode) {
      try { const { smoke } = await import('./smoke.js'); await smoke(window, mailbox, poll); }
      finally { closing = true; clearInterval(timer); await telemetry?.stop(); await mailbox.close(); await fs.rm(root, { recursive: true, force: true }); await fs.rm(userData, { recursive: true, force: true }); }
      app.exit(0);
    }
  }).catch(error => { console.error(`Pip Source could not start: ${(error as Error).message}`); if (smokeMode) app.exit(1); else app.quit(); });
  app.on('window-all-closed', () => app.quit());
  app.on('before-quit', event => {
    if (closing) return;
    event.preventDefault(); closing = true;
    if (timer) clearInterval(timer); if (mouseTimer) clearInterval(mouseTimer);
    void (async () => { await telemetry?.stop(); await mailbox?.close(); tray?.destroy(); app.quit(); })().catch(() => app.quit());
  });
}

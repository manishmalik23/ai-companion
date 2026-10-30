import * as vscode from 'vscode';
import { randomUUID } from 'node:crypto';
import { PrivateLeaseWriter, registryDirectory, RegistryError } from './registry';
import { SharedRefresh } from './refresh';
import { codexCapability, CodexCapability, openCodexSession, supportsCodexVersion } from './codex';
import { cleanTerminalName, EXTENSION_ID, focusExistingTerminal, isProcessId, localWorkspaces,
  localPlatformUnavailableReason, parseTerminalRequest, readTerminalProcessId, ResolvedRoutes, serializeSessionURI, SessionLinkLease,
  validateResolvedRoutes, WINDOW_ENV } from './protocol';

class SessionLinks implements vscode.Disposable {
  readonly windowKey = randomUUID();
  private readonly writer: PrivateLeaseWriter;
  private readonly priorEnvironment = process.env[WINDOW_ENV];
  private readonly timer: NodeJS.Timeout;
  private disposed = false;
  private readonly refresher = new SharedRefresh(() => this.refreshOnce());
  private routes?: ResolvedRoutes;
  private errorCategory?: string;
  private navigationGeneration = 0;
  private readonly subscriptions: vscode.Disposable[] = [];

  constructor(private readonly context: vscode.ExtensionContext, private readonly output: vscode.OutputChannel) {
    const directory = registryDirectory();
    if (!directory) throw new RegistryError('unsafe_directory');
    this.writer = new PrivateLeaseWriter(directory, this.windowKey, process.pid);
    process.env[WINDOW_ENV] = this.windowKey;
    context.environmentVariableCollection.persistent = false;
    context.environmentVariableCollection.replace(WINDOW_ENV, this.windowKey);
    this.subscriptions.push(vscode.window.registerUriHandler({ handleUri: uri => this.handleURI(uri) }),
      vscode.workspace.onDidChangeWorkspaceFolders(() => { void this.refresh(); }),
      vscode.extensions.onDidChange(() => { void this.refresh(); }),
      vscode.window.onDidOpenTerminal(() => { void this.refresh(); }),
      vscode.window.onDidCloseTerminal(() => { void this.refresh(); }));
    this.timer = setInterval(() => { void this.refresh(); }, 10_000);
    this.timer.unref();
  }

  private async terminalIdentities(): Promise<SessionLinkLease['terminals']> {
    const terminals = vscode.window.terminals.slice(0, 64);
    return (await Promise.all(terminals.map(async terminal => {
      const pid = await readTerminalProcessId(terminal);
      return pid !== undefined && isProcessId(pid) ? { processId: pid, name: cleanTerminalName(terminal.name) } : undefined;
    }))).filter((value): value is SessionLinkLease['terminals'][number] => value !== undefined);
  }

  refresh(): Promise<boolean> { return this.refresher.request(); }

  private codexVersion(): unknown {
    return vscode.extensions.getExtension('openai.chatgpt')?.packageJSON?.version;
  }

  private async refreshOnce(): Promise<boolean> {
    if (this.disposed || localPlatformUnavailableReason(process.platform, vscode.env.remoteName)) return false;
    let success = false;
    let failureCategory = 'window_route_resolution_failed';
    try {
      const codexVersion = this.codexVersion();
      const [claude, terminal, codex] = await Promise.all([
        vscode.env.asExternalUri(vscode.Uri.parse(`${vscode.env.uriScheme}://anthropic.claude-code/open`)),
        vscode.env.asExternalUri(vscode.Uri.parse(`${vscode.env.uriScheme}://${EXTENSION_ID}/terminal`)),
        supportsCodexVersion(codexVersion) ?
          vscode.env.asExternalUri(vscode.Uri.parse(`${vscode.env.uriScheme}://${EXTENSION_ID}/codex`)).then(uri => uri, () => undefined) : undefined
      ]);
      failureCategory = 'invalid_window_route';
      const routes = validateResolvedRoutes(serializeSessionURI(claude), serializeSessionURI(terminal));
      let capability: CodexCapability | undefined;
      if (codex !== undefined && codexVersion === this.codexVersion()) {
        try { capability = codexCapability(codexVersion, serializeSessionURI(codex), routes); }
        catch { /* An optional Codex route never disables the existing Claude and terminal routes. */ }
      }
      failureCategory = 'terminal_identity_unavailable';
      const terminals = await this.terminalIdentities();
      if (this.disposed) return false;
      failureCategory = 'registry_operation_failed';
      await this.writer.write({ schemaVersion: 1, windowKey: this.windowKey, processId: process.pid,
        updatedAt: Date.now() / 1000, workspaces: localWorkspaces(vscode.workspace.workspaceFolders ?? []),
        claudeSessionURL: routes.claudeSessionURL, terminalURL: routes.terminalURL, terminals, ...capability });
      if (this.disposed) { await this.writer.removeAsync(); return false; }
      this.routes = routes; success = true;
      if (this.errorCategory) this.output.appendLine('Local session links are available again.');
      this.errorCategory = undefined;
    } catch (error) {
      this.routes = undefined;
      await this.writer.removeAsync();
      const category = error instanceof RegistryError ? error.code : failureCategory;
      if (category !== this.errorCategory) this.output.appendLine(`Session links unavailable: ${category}.`);
      this.errorCategory = category;
    }
    return success;
  }

  private async handleURI(uri: vscode.Uri): Promise<void> {
    if (this.disposed) return;
    let value: string;
    try { value = serializeSessionURI(uri); }
    catch { return; }
    if (uri.path === '/codex') {
      const routes = this.routes;
      if (!routes) return;
      const generation = ++this.navigationGeneration;
      const result = await openCodexSession(value, this.windowKey, routes, {
        extensionVersion: () => this.codexVersion(),
        resolveURI: async target => vscode.env.asExternalUri(vscode.Uri.parse(target)),
        openURI: async target => vscode.env.openExternal(vscode.Uri.parse(target)),
        isCurrent: () => !this.disposed && generation === this.navigationGeneration
      });
      if (result === 'unsupported_version') {
        void vscode.window.showWarningMessage('Pip session links are unavailable for this Codex extension version.');
      } else if (result === 'unavailable_window_route') {
        void vscode.window.showWarningMessage('Pip could not verify the original VS Code window for this Codex session.');
      } else if (result === 'open_failed') {
        void vscode.window.showWarningMessage('VS Code could not open this existing Codex session.');
      }
      return;
    }
    const pid = parseTerminalRequest(value, this.windowKey, this.routes?.windowId);
    if (pid === undefined) return;
    if (!await focusExistingTerminal(vscode.window.terminals, pid)) {
      void vscode.window.showWarningMessage('Pip could not find that existing terminal. It may have closed.');
    }
  }

  dispose(): void {
    this.disposed = true;
    this.refresher.dispose();
    clearInterval(this.timer);
    this.subscriptions.forEach(subscription => subscription.dispose());
    this.writer.remove();
    this.context.environmentVariableCollection.delete(WINDOW_ENV);
    if (process.env[WINDOW_ENV] === this.windowKey) {
      if (this.priorEnvironment === undefined) delete process.env[WINDOW_ENV];
      else process.env[WINDOW_ENV] = this.priorEnvironment;
    }
  }
}

export function activate(context: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel('Pip Session Links');
  const reason = localPlatformUnavailableReason(process.platform, vscode.env.remoteName);
  let links: SessionLinks | undefined;
  context.subscriptions.push(output, vscode.commands.registerCommand('pipSessionLinks.refresh', async () => {
    if (!links) {
      void vscode.window.showWarningMessage(reason === 'remote_window' ?
        'Pip session links support local VS Code windows only. Remote, WSL and dev-container windows are unavailable.' :
        'Pip session links are unavailable. See the Pip Session Links output for details.');
      return;
    }
    if (await links.refresh()) void vscode.window.showInformationMessage('Pip session links refreshed for this VS Code window.');
    else void vscode.window.showWarningMessage('Pip session links are unavailable. See the Pip Session Links output for details.');
  }));
  if (reason) {
    output.appendLine(`Session links unavailable: ${reason}. Supports local macOS and Windows VS Code windows only.`);
    return;
  }
  try { links = new SessionLinks(context, output); }
  catch {
    output.appendLine('Session links unavailable: registry_operation_failed.');
    return;
  }
  context.subscriptions.push(links);
  void links.refresh();
}

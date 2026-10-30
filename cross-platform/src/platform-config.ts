/** Shell-form hooks contain only reviewed launcher arguments, never tool text.
 * Windows uses PowerShell's encoded-command transport so cmd, PowerShell and
 * Git Bash cannot reinterpret spaces or metacharacters in an installed path.
 * https://code.claude.com/docs/en/hooks#command-hook-fields
 * https://learn.chatgpt.com/docs/hooks#config-shape
 */
const windowsPrefix = 'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ';
const scriptPrefix = '[Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false; $pipArguments = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'';
const scriptSuffix = '\'))); $pipExecutable = $pipArguments[0]; $pipRest = $pipArguments[1..($pipArguments.Length - 1)]; & $pipExecutable @pipRest; exit $LASTEXITCODE';

function validArguments(args: readonly string[]): void {
  if (args.length < 2 || args.length > 64 || args.some(value => typeof value !== 'string' || value.length === 0 ||
      Buffer.byteLength(value) > 16_384 || /[\u0000-\u001f\u007f]/.test(value))) throw new Error('Invalid hook launcher arguments.');
}
export function quoteHookCommand(args: readonly string[], platform: NodeJS.Platform = process.platform): string {
  validArguments(args);
  if (platform === 'win32') {
    const payload = Buffer.from(JSON.stringify(args), 'utf8').toString('base64');
    return windowsPrefix + Buffer.from(scriptPrefix + payload + scriptSuffix, 'utf16le').toString('base64');
  }
  return args.map(value => "'" + value.replaceAll("'", "'\\''") + "'").join(' ');
}
export function hookShellOptions(source: 'claude' | 'codex', platform: NodeJS.Platform = process.platform): { shell?: 'powershell' } {
  return source === 'claude' && platform === 'win32' ? { shell: 'powershell' } : {};
}

/** Parse a literal command only. Operators, substitutions and malformed quoting
 * make ownership unknown and are preserved rather than executed or removed. */
export function hookArguments(command: string): string[] | undefined {
  if (typeof command !== 'string' || command.length > 128_000 || /[\r\n\0]/.test(command)) return undefined;
  if (command.startsWith(windowsPrefix)) {
    try {
      const encoded = command.slice(windowsPrefix.length);
      if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) return undefined;
      const script = Buffer.from(encoded, 'base64').toString('utf16le');
      if (!script.startsWith(scriptPrefix) || !script.endsWith(scriptSuffix)) return undefined;
      const payload = script.slice(scriptPrefix.length, -scriptSuffix.length);
      if (!/^[A-Za-z0-9+/]+={0,2}$/.test(payload)) return undefined;
      const args: unknown = JSON.parse(Buffer.from(payload, 'base64').toString('utf8'));
      if (!Array.isArray(args)) return undefined;
      validArguments(args);
      return quoteHookCommand(args, 'win32') === command ? args : undefined;
    } catch { return undefined; }
  }
  const result: string[] = []; let current = '', quote = '', started = false;
  for (let i = 0; i < command.length; i++) {
    const char = command[i]!;
    if (quote) {
      if (char === quote) quote = '';
      else if (quote === '"' && /[$`\\]/.test(char)) return undefined;
      else current += char;
    } else if (char === "'" || char === '"') { quote = char; started = true; }
    else if (/\s/.test(char)) { if (started) { result.push(current); current = ''; started = false; } }
    else if (char === '\\') { if (i + 1 >= command.length) return undefined; current += command[++i]!; started = true; }
    else if (/[;&|<>$`()!*?]/.test(char)) return undefined;
    else { current += char; started = true; }
  }
  if (quote) return undefined;
  if (started) result.push(current);
  return result.length ? result : undefined;
}

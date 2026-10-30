import { execFile, execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

export type WindowsPathKind = 'directory' | 'file';
export interface WindowsPathCheck { path: string; kind: WindowsPathKind }
export const WINDOWS_SECURITY_TIMEOUT_MS = 5_000;
export const MAX_WINDOWS_SECURITY_PATHS = 65;
const REQUEST_LIMIT = 16_384, OUTPUT_LIMIT = 524_288, FULL_CONTROL = 2_032_127;
const SID = /^S-1-\d+(?:-\d+){1,15}$/;
const TRUSTED_SIDS = ['S-1-5-18', 'S-1-5-32-544']; // Local System and local Administrators.

/** A local drive path only: no UNC, devices, alternate streams or Win32 name aliases. */
export function windowsSecurityPath(value: unknown): string | undefined {
  if (typeof value !== 'string' || value.length > 4_096 || !/^[A-Za-z]:[\\/]/.test(value) ||
      /[\u0000-\u001f\u007f-\u009f]/.test(value)) return;
  const parts = value.slice(3).replaceAll('/', '\\').replace(/\\+$/, '').split('\\');
  if (!parts.length || parts.length > 64 || parts.some(part => !part || part === '.' || part === '..' ||
      part.length > 255 || /[<>:"|?*]/.test(part) || /[. ]$/.test(part) ||
      /^(?:con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\.|$)/i.test(part))) return;
  return path.win32.normalize(value.replaceAll('/', '\\')).replace(/\\+$/, '');
}

// Fixed code only. Caller paths travel in a base64 JSON environment value,
// never in executable script text or a shell command. Windows PowerShell 5.1
// supplies the .NET Framework DirectorySecurity creation overload.
export const WINDOWS_SECURITY_SCRIPT = String.raw`
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Path-Attributes([string] $value) {
  try { return [int][System.IO.File]::GetAttributes($value) }
  catch {
    $failure = $_.Exception
    while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
    if ($failure -is [System.IO.FileNotFoundException] -or $failure -is [System.IO.DirectoryNotFoundException]) { return $null }
    throw
  }
}
function Assert-Components([string] $value, [string] $kind, [bool] $create) {
  $root = [System.IO.Path]::GetPathRoot($value)
  if ([System.IO.DriveInfo]::new($root).DriveType -ne [System.IO.DriveType]::Fixed) { throw 'unsafe_drive' }
  $current = $root
  $parts = $value.Substring($root.Length).Split([char]'\')
  $rootAttributes = Path-Attributes $root
  if ($null -eq $rootAttributes -or ($rootAttributes -band 1024) -ne 0 -or ($rootAttributes -band 16) -eq 0) { throw 'unsafe_path' }
  for ($index = 0; $index -lt $parts.Length; $index++) {
    $current = [System.IO.Path]::Combine($current, $parts[$index])
    $attributes = Path-Attributes $current
    if ($null -eq $attributes -and $create) {
      [void][System.IO.Directory]::CreateDirectory($current, $script:privateAcl)
      $attributes = Path-Attributes $current
      Assert-Private (Read-Private $current 'directory' -1)
    }
    if ($null -eq $attributes -or ($attributes -band 1024) -ne 0) { throw 'unsafe_path' }
    $directory = ($attributes -band 16) -ne 0
    $expectedDirectory = $index -lt ($parts.Length - 1) -or $kind -eq 'directory'
    if ($directory -ne $expectedDirectory) { throw 'unsafe_kind' }
  }
}
function Read-Private([string] $value, [string] $kind, [int] $index) {
  $acl = if ($kind -eq 'directory') { [System.IO.Directory]::GetAccessControl($value) } else { [System.IO.File]::GetAccessControl($value) }
  $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
    @{ sid = $_.IdentityReference.Value; access = [string]$_.AccessControlType; rights = [long]$_.FileSystemRights;
       inheritance = [int]$_.InheritanceFlags; propagation = [int]$_.PropagationFlags; inherited = [bool]$_.IsInherited }
  })
  return @{ index = $index; kind = $kind; ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value;
            driveType = [string][System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($value)).DriveType;
            protected = [bool]$acl.AreAccessRulesProtected; componentsSafe = $true; rules = $rules }
}
function Assert-Private($entry) {
  $ownerAllowed = $entry.ownerSid -eq $script:currentSid -or
    ($entry.kind -eq 'file' -and $entry.ownerSid -in @('S-1-5-18', 'S-1-5-32-544'))
  if (-not $ownerAllowed -or $entry.driveType -ne 'Fixed' -or ($entry.kind -eq 'directory' -and -not $entry.protected) -or
      $entry.rules.Count -lt 1 -or $entry.rules.Count -gt 32) { throw 'unsafe_acl' }
  $usable = $false
  foreach ($rule in $entry.rules) {
    if ($rule.access -ne 'Allow' -or $rule.sid -notin @($script:currentSid, 'S-1-5-18', 'S-1-5-32-544') -or
        $rule.rights -lt 1 -or $rule.rights -gt 2147483647 -or $rule.inheritance -lt 0 -or $rule.inheritance -gt 3 -or
        $rule.propagation -lt 0 -or $rule.propagation -gt 3) { throw 'unsafe_acl' }
    if ($rule.sid -eq $script:currentSid -and ($rule.rights -band 2032127) -eq 2032127 -and
        ($rule.propagation -band 2) -eq 0 -and
        ($entry.kind -ne 'directory' -or ($rule.inheritance -eq 3 -and $rule.propagation -eq 0))) { $usable = $true }
  }
  if (-not $usable) { throw 'unsafe_acl' }
}
try {
  $request = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($env:PIP_SESSION_LINK_SECURITY_REQUEST)) | ConvertFrom-Json
  $script:currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $script:privateAcl = [System.Security.AccessControl.DirectorySecurity]::new()
  $script:privateAcl.SetOwner([System.Security.Principal.SecurityIdentifier]::new($script:currentSid))
  $script:privateAcl.SetAccessRuleProtection($true, $false)
  foreach ($sid in @($script:currentSid, 'S-1-5-18', 'S-1-5-32-544')) {
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
      [System.Security.Principal.SecurityIdentifier]::new($sid), [System.Security.AccessControl.FileSystemRights]::FullControl,
      ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
      [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
    [void]$script:privateAcl.AddAccessRule($rule)
  }
  $entries = @()
  for ($index = 0; $index -lt $request.paths.Count; $index++) {
    $item = $request.paths[$index]
    Assert-Components $item.path $item.kind ($request.operation -eq 'ensure')
    $entry = Read-Private $item.path $item.kind $index
    Assert-Private $entry
    Assert-Components $item.path $item.kind $false
    $entries += $entry
  }
  [Console]::Out.Write((@{ schemaVersion = 1; nonce = $request.nonce; currentUserSid = $script:currentSid; entries = $entries } | ConvertTo-Json -Compress -Depth 8))
} catch {
  [Console]::Error.Write('Windows session-link storage is unavailable.')
  exit 1
}
`;

export interface WindowsSecurityInvocation {
  executable: string;
  args: readonly string[];
  env: NodeJS.ProcessEnv;
  timeout: number;
  maxBuffer: number;
  windowsHide: boolean;
}
export interface WindowsSecurityOptions {
  platform?: NodeJS.Platform;
  env?: NodeJS.ProcessEnv;
  runSync?: (invocation: WindowsSecurityInvocation) => string;
  runAsync?: (invocation: WindowsSecurityInvocation) => Promise<string>;
}
interface Prepared { invocation: WindowsSecurityInvocation; paths: WindowsPathCheck[]; nonce: string }

function unavailable(): Error { return new Error('Windows session-link storage is unavailable.'); }

function prepare(paths: readonly WindowsPathCheck[], operation: 'inspect' | 'ensure', options: WindowsSecurityOptions): Prepared {
  if ((options.platform ?? process.platform) !== 'win32' || paths.length < 1 || paths.length > MAX_WINDOWS_SECURITY_PATHS ||
      operation === 'ensure' && (paths.length !== 1 || paths[0]?.kind !== 'directory')) throw unavailable();
  const normalized = paths.map(item => {
    const value = windowsSecurityPath(item.path);
    if (!value || !['directory', 'file'].includes(item.kind)) throw unavailable();
    return { path: value, kind: item.kind };
  });
  if (new Set(normalized.map(item => item.path.toLowerCase())).size !== normalized.length) throw unavailable();
  const env = options.env ?? process.env, systemRoot = windowsSecurityPath(env.SystemRoot ?? env.SYSTEMROOT);
  if (!systemRoot) throw unavailable();
  const nonce = randomUUID(), payload = Buffer.from(JSON.stringify({ operation, nonce, paths: normalized }), 'utf8');
  if (payload.length > REQUEST_LIMIT) throw unavailable();
  const base = path.win32.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0');
  return { paths: normalized, nonce, invocation: {
    executable: path.win32.join(base, 'powershell.exe'),
    args: ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', WINDOWS_SECURITY_SCRIPT],
    env: { ...env, PSModulePath: path.win32.join(base, 'Modules'), PIP_SESSION_LINK_SECURITY_REQUEST: payload.toString('base64') },
    timeout: WINDOWS_SECURITY_TIMEOUT_MS, maxBuffer: OUTPUT_LIMIT, windowsHide: true
  } };
}

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === 'object' && !Array.isArray(value); }
/** The PowerShell result contains ACL facts only, never lease or chat contents. */
export function validateWindowsSecurityReport(value: unknown, checks: readonly WindowsPathCheck[], nonce: string): void {
  if (!record(value) || value.schemaVersion !== 1 || value.nonce !== nonce || typeof value.currentUserSid !== 'string' ||
      !SID.test(value.currentUserSid) || TRUSTED_SIDS.includes(value.currentUserSid) ||
      !Array.isArray(value.entries) || value.entries.length !== checks.length) throw unavailable();
  const user = value.currentUserSid, permitted = new Set([user, ...TRUSTED_SIDS]);
  value.entries.forEach((entry: unknown, index: number) => {
    const kind = checks[index]?.kind;
    if (!record(entry) || entry.index !== index || entry.kind !== kind || entry.driveType !== 'Fixed' ||
        !(entry.ownerSid === user || kind === 'file' && typeof entry.ownerSid === 'string' && TRUSTED_SIDS.includes(entry.ownerSid)) || entry.componentsSafe !== true ||
        typeof entry.protected !== 'boolean' || kind === 'directory' && !entry.protected ||
        !Array.isArray(entry.rules) || entry.rules.length < 1 || entry.rules.length > 32) throw unavailable();
    let usable = false;
    for (const rule of entry.rules) {
      if (!record(rule) || typeof rule.sid !== 'string' || !permitted.has(rule.sid) || rule.access !== 'Allow' ||
          !Number.isSafeInteger(rule.rights) || Number(rule.rights) < 1 || Number(rule.rights) > 2_147_483_647 ||
          !Number.isInteger(rule.inheritance) || Number(rule.inheritance) < 0 || Number(rule.inheritance) > 3 ||
          !Number.isInteger(rule.propagation) || Number(rule.propagation) < 0 || Number(rule.propagation) > 3 ||
          typeof rule.inherited !== 'boolean') throw unavailable();
      if (rule.sid === user && (Number(rule.rights) & FULL_CONTROL) === FULL_CONTROL && (Number(rule.propagation) & 2) === 0 &&
          (kind !== 'directory' || rule.inheritance === 3 && rule.propagation === 0)) usable = true;
    }
    if (!usable) throw unavailable();
  });
}

function validateOutput(output: string, prepared: Prepared): void {
  if (typeof output !== 'string' || Buffer.byteLength(output, 'utf8') > OUTPUT_LIMIT) throw unavailable();
  let report: unknown;
  try { report = JSON.parse(output.replace(/^\uFEFF/, '')); } catch { throw unavailable(); }
  validateWindowsSecurityReport(report, prepared.paths, prepared.nonce);
}

function runSync(invocation: WindowsSecurityInvocation): string {
  return execFileSync(invocation.executable, [...invocation.args], { env: invocation.env, encoding: 'utf8',
    timeout: invocation.timeout, maxBuffer: invocation.maxBuffer, windowsHide: invocation.windowsHide });
}
function runAsync(invocation: WindowsSecurityInvocation): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(invocation.executable, [...invocation.args], { env: invocation.env, encoding: 'utf8',
      timeout: invocation.timeout, maxBuffer: invocation.maxBuffer, windowsHide: invocation.windowsHide },
    (error, stdout) => error ? reject(unavailable()) : resolve(stdout));
  });
}
function inspect(paths: readonly WindowsPathCheck[], operation: 'inspect' | 'ensure', options: WindowsSecurityOptions): void {
  try {
    const prepared = prepare(paths, operation, options);
    validateOutput((options.runSync ?? runSync)(prepared.invocation), prepared);
  } catch { throw unavailable(); }
}
async function inspectAsync(paths: readonly WindowsPathCheck[], operation: 'inspect' | 'ensure', options: WindowsSecurityOptions): Promise<void> {
  try {
    const prepared = prepare(paths, operation, options);
    validateOutput(await (options.runAsync ?? runAsync)(prepared.invocation), prepared);
  } catch { throw unavailable(); }
}

export function inspectWindowsPaths(paths: readonly WindowsPathCheck[], options: WindowsSecurityOptions = {}): void {
  inspect(paths, 'inspect', options);
}
export function inspectWindowsPath(value: string, kind: WindowsPathKind, options: WindowsSecurityOptions = {}): void {
  inspectWindowsPaths([{ path: value, kind }], options);
}
export function ensureWindowsDirectory(directory: string, options: WindowsSecurityOptions = {}): void {
  inspect([{ path: directory, kind: 'directory' }], 'ensure', options);
}
export function inspectWindowsPathsAsync(paths: readonly WindowsPathCheck[], options: WindowsSecurityOptions = {}): Promise<void> {
  return inspectAsync(paths, 'inspect', options);
}
export function inspectWindowsPathAsync(value: string, kind: WindowsPathKind, options: WindowsSecurityOptions = {}): Promise<void> {
  return inspectWindowsPathsAsync([{ path: value, kind }], options);
}
export function ensureWindowsDirectoryAsync(directory: string, options: WindowsSecurityOptions = {}): Promise<void> {
  return inspectAsync([{ path: directory, kind: 'directory' }], 'ensure', options);
}

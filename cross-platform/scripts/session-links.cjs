// Build our private VSIX and install it through the existing VS Code CLI.
// No shell, code.cmd interpolation, Marketplace package or Pip executable is used.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { inflateRawSync } = require('node:zlib');

const VERSION = '0.3.0';
const EXTENSION_ID = 'pip-local.pip-session-links';
const HELPER_ROOT = path.resolve(__dirname, '../../vscode-session-links');

function parseArguments(args) {
  const [action, ...flags] = args;
  if (!['build', 'install'].includes(action)) throw new Error('Use yarn session-links:build or yarn session-links:install.');
  let insiders = false, profile;
  for (let index = 0; index < flags.length; index += 1) {
    if (flags[index] === '--insiders' && !insiders) insiders = true;
    else if (flags[index] === '--profile' && profile === undefined) {
      profile = flags[++index];
      if (typeof profile !== 'string' || !profile.trim() || profile.length > 120 || profile.startsWith('-') || /[\u0000-\u001f\u007f]/.test(profile)) {
        throw new Error('--profile needs the exact existing VS Code profile name.');
      }
    } else throw new Error('Only --insiders and --profile <existing-name> are supported.');
  }
  return { action, insiders, profile };
}

function validateHelperPackage(pkg) {
  const development = { '@types/node': '22.18.6', '@types/vscode': '1.95.0', typescript: '5.9.3' };
  const scripts = { build: 'tsc -p tsconfig.json', test: 'yarn build && node --test dist/test/*.test.js', package: 'yarn build && node scripts/package.mjs' };
  if (!pkg || pkg.name !== 'pip-session-links' || pkg.publisher !== 'pip-local' || pkg.version !== VERSION ||
      pkg.main !== './dist/src/extension.js' || pkg.packageManager !== 'yarn@1.22.22' ||
      Object.keys(pkg.dependencies || {}).length || (pkg.extensionDependencies || []).length || (pkg.extensionPack || []).length ||
      JSON.stringify(Object.entries(pkg.devDependencies || {}).sort()) !== JSON.stringify(Object.entries(development).sort()) ||
      JSON.stringify(Object.entries(pkg.scripts || {}).sort()) !== JSON.stringify(Object.entries(scripts).sort())) {
    throw new Error('The local Pip Session Links package changed. Review/update this installer before building it.');
  }
}

function yarnEntry(env = process.env, fileExists = regularFile) {
  const entry = env.npm_execpath;
  if (typeof entry !== 'string' || !path.isAbsolute(entry) || !/^yarn\.(?:js|cjs)$/i.test(path.basename(entry)) || !fileExists(entry)) {
    throw new Error('Run this command through Yarn 1.22.22: yarn session-links:install.');
  }
  return entry;
}

function regularFile(file) {
  try { const stat = fs.lstatSync(file); return stat.isFile() && !stat.isSymbolicLink(); }
  catch { return false; }
}

function runCommand(command, args, options, runner = spawnSync) {
  const result = runner(command, args, { ...options, shell: false });
  if (result.error) throw new Error(`Could not run ${path.basename(command)}: ${result.error.code || 'launch failed'}.`);
  if (result.status !== 0) throw new Error(`Command failed with exit status ${result.status ?? 'unknown'}. Follow the output above; no policy or trust setting was bypassed.`);
  return result;
}

function readVSIXManifest(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length > 2 * 1024 * 1024) throw new Error('Unexpected Pip VSIX size.');
  let offset = 0, manifest;
  const seen = new Set();
  while (offset + 30 <= buffer.length && buffer.readUInt32LE(offset) === 0x04034b50) {
    const flags = buffer.readUInt16LE(offset + 6), method = buffer.readUInt16LE(offset + 8);
    const compressedSize = buffer.readUInt32LE(offset + 18), uncompressedSize = buffer.readUInt32LE(offset + 22);
    const nameLength = buffer.readUInt16LE(offset + 26), extraLength = buffer.readUInt16LE(offset + 28);
    const begin = offset + 30 + nameLength + extraLength, end = begin + compressedSize;
    if (flags !== 0x800 || method !== 8 || end > buffer.length) throw new Error('Unsupported Pip VSIX archive.');
    const name = buffer.subarray(offset + 30, offset + 30 + nameLength).toString('utf8');
    if (seen.has(name) || name.includes('..') || name.startsWith('/') || name.includes('\\')) throw new Error('Unsafe Pip VSIX entry.');
    seen.add(name);
    if (name === 'extension/package.json') {
      if (uncompressedSize > 65_536) throw new Error('Unexpected VSIX manifest size.');
      const data = inflateRawSync(buffer.subarray(begin, end), { maxOutputLength: 65_536 });
      if (data.length !== uncompressedSize) throw new Error('Invalid VSIX manifest.');
      manifest = JSON.parse(data.toString('utf8'));
    }
    offset = end;
  }
  validateHelperPackage(manifest);
  return manifest;
}

function windowsRoot(value) {
  return typeof value === 'string' && /^[A-Za-z]:[\\/]/.test(value) &&
    !/[\u0000-\u001f\u007f<>"|?*]/.test(value) && !value.slice(2).includes(':') &&
    !value.split(/[\\/]/).includes('..') ? value : undefined;
}

function vscodeCandidates(platform, env, home, insiders) {
  const name = insiders ? 'Microsoft VS Code Insiders' : 'Microsoft VS Code';
  if (platform === 'win32') {
    const roots = [windowsRoot(env.LOCALAPPDATA) && path.win32.join(env.LOCALAPPDATA, 'Programs'),
      windowsRoot(env.ProgramFiles), windowsRoot(env['ProgramFiles(x86)'])].filter(Boolean);
    return [...new Set(roots)].map(root => {
      const directory = path.win32.join(root, name);
      return { executable: path.win32.join(directory, insiders ? 'Code - Insiders.exe' : 'Code.exe'),
        cli: path.win32.join(directory, 'resources', 'app', 'out', 'cli.js') };
    });
  }
  if (platform === 'darwin') {
    const app = insiders ? 'Visual Studio Code - Insiders.app' : 'Visual Studio Code.app';
    return ['/Applications', path.join(home, 'Applications')].map(folder => {
      const contents = path.join(folder, app, 'Contents');
      return { executable: path.join(contents, 'MacOS', 'Electron'), cli: path.join(contents, 'Resources', 'app', 'out', 'cli.js') };
    });
  }
  return [];
}

function installationCommand(target, archive, options, env) {
  const args = [target.cli, '--install-extension', archive, '--force'];
  if (options.profile !== undefined) args.push('--profile', options.profile);
  return { command: target.executable, args, options: { stdio: 'inherit', env: { ...env, ELECTRON_RUN_AS_NODE: '1' }, shell: false } };
}

function installBuiltHelper(archive, options, runtime = {}) {
  const platform = runtime.platform || process.platform, env = runtime.env || process.env;
  const fileExists = runtime.fileExists || regularFile;
  const log = runtime.log || console.log;
  const target = vscodeCandidates(platform, env, runtime.home || require('node:os').homedir(), options.insiders)
    .find(candidate => fileExists(candidate.executable) && fileExists(candidate.cli));
  if (!target) {
    throw new Error(`A standard local ${options.insiders ? 'VS Code Insiders' : 'VS Code'} installation was not found. In your chosen VS Code profile, run Extensions: Install from VSIX... and select:\n${archive}`);
  }
  log(`Installing ${EXTENSION_ID} ${VERSION} into ${options.insiders ? 'VS Code Insiders' : 'VS Code'}${options.profile ? ` profile "${options.profile}"` : ' (default profile)'}.`);
  const invocation = installationCommand(target, archive, options, env);
  runCommand(invocation.command, invocation.args, invocation.options, runtime.runner);
}

function main(args = process.argv.slice(2)) {
  const options = parseArguments(args);
  if (!['win32', 'darwin'].includes(process.platform)) throw new Error('Pip Session Links supports local macOS and native Windows VS Code only. WSL/remote hosts are unsupported.');
  const pkg = JSON.parse(fs.readFileSync(path.join(HELPER_ROOT, 'package.json'), 'utf8'));
  validateHelperPackage(pkg);
  const yarn = yarnEntry(), environment = { ...process.env };
  delete environment.ELECTRON_RUN_AS_NODE;
  const execution = { cwd: HELPER_ROOT, env: environment, stdio: 'inherit' };
  const version = runCommand(process.execPath, [yarn, '--version'], { ...execution, stdio: 'pipe', encoding: 'utf8' });
  if (version.stdout.trim() !== '1.22.22') throw new Error('Use the pinned Yarn 1.22.22 version.');
  runCommand(process.execPath, [yarn, 'install', '--frozen-lockfile', '--ignore-scripts'], execution);
  runCommand(process.execPath, [yarn, 'run', 'package'], execution);
  const archive = path.join(HELPER_ROOT, 'artifacts', `pip-session-links-${VERSION}.vsix`);
  if (!regularFile(archive)) throw new Error('The helper build did not produce a regular VSIX file.');
  readVSIXManifest(fs.readFileSync(archive));
  console.log(`Built ${EXTENSION_ID} ${VERSION}:\n${archive}`);
  if (options.action === 'build') console.log('In VS Code, run Extensions: Install from VSIX... and select that file.');
  else installBuiltHelper(archive, options);
  console.log('After current agent work finishes: Developer: Reload Window, then Pip: Refresh Session Links in each local VS Code window.');
  console.log('Find Pip Session Links under Extensions, not Chat Agents. It does not add a chat agent or sidebar icon.');
}

module.exports = { VERSION, EXTENSION_ID, parseArguments, validateHelperPackage, yarnEntry, readVSIXManifest,
  vscodeCandidates, installationCommand, installBuiltHelper, runCommand, main };
if (require.main === module) {
  try { main(); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}

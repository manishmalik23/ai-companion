import * as fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { directory } from './mailbox';

export const BUILT_INS = ['default', 'sunny', 'mochi', 'boba', 'lumi', 'mallow', 'sprout', 'peach-puff', 'lavender-mochi', 'mint-bean', 'nimbo', 'chai', 'plumo'] as const;
export type BuiltIn = typeof BUILT_INS[number];
export interface AppearanceState {
  selection: BuiltIn | 'custom';
  custom?: { kind: 'still' | 'sprite'; dataUrl: string; name: string };
}
interface Profile { version: 1; selection: string; custom?: { kind: string; mime: string; bytes: string; name: string } }
export interface ImageDimensions { width: number; height: number }
export type DecodeImage = (bytes: Buffer) => ImageDimensions | undefined;
export const MAX_CHARACTER_BYTES = 10 * 1024 * 1024;
const PROFILE_LIMIT = Math.ceil(MAX_CHARACTER_BYTES * 4 / 3) + 8192;

// Character images have a separate, larger bound. Approval mailboxes retain their 1 MB limit.
async function readProfile(root: string): Promise<unknown> {
  const file = path.join(root, 'appearance.json'), before = await fs.lstat(file);
  if (!before.isFile() || before.isSymbolicLink()) throw new Error('Invalid character profile.');
  const handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0));
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > PROFILE_LIMIT || stat.ino !== before.ino || stat.dev !== before.dev ||
        (process.platform !== 'win32' && (stat.uid !== process.getuid!() || (stat.mode & 0o077) !== 0))) throw new Error('Invalid character profile.');
    const buffer = Buffer.alloc(PROFILE_LIMIT + 1), { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    if (bytesRead > PROFILE_LIMIT) throw new Error('Character profile is too large.');
    return JSON.parse(buffer.subarray(0, bytesRead).toString());
  } finally { await handle.close(); }
}
async function writeProfile(root: string, value: unknown): Promise<void> {
  await directory(root);
  const data = JSON.stringify(value);
  if (Buffer.byteLength(data) > PROFILE_LIMIT) throw new Error('Character profile is too large.');
  const temporary = path.join(root, `.appearance-${randomUUID()}`);
  try { await fs.writeFile(temporary, data, { flag: 'wx', mode: 0o600 }); await fs.rename(temporary, path.join(root, 'appearance.json')); }
  finally { await fs.unlink(temporary).catch(() => undefined); }
}

function mime(bytes: Buffer): string | undefined {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return 'image/png';
  if (bytes.length >= 12 && bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  return undefined;
}
function headerDimensions(bytes: Buffer, contentType: string): ImageDimensions | undefined {
  if (contentType === 'image/png') {
    if (bytes.length < 24 || bytes.toString('ascii', 12, 16) !== 'IHDR') return undefined;
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  }
  if (bytes.length < 25) return undefined;
  const chunk = bytes.toString('ascii', 12, 16);
  if (chunk === 'VP8X' && bytes.length >= 30) return { width: bytes.readUIntLE(24, 3) + 1, height: bytes.readUIntLE(27, 3) + 1 };
  if (chunk === 'VP8L' && bytes[20] === 0x2f) {
    const bits = bytes.readUInt32LE(21); return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  if (chunk === 'VP8 ' && bytes.length >= 30 && bytes.subarray(23, 26).equals(Buffer.from([0x9d, 0x01, 0x2a]))) {
    return { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff };
  }
  return undefined;
}
function customState(kind: unknown, bytes: Buffer, name: unknown, decode: DecodeImage): AppearanceState {
  if (!['still', 'sprite'].includes(String(kind)) || bytes.length > MAX_CHARACTER_BYTES || bytes.length === 0 ||
      typeof name !== 'string' || name.length === 0 || name.length > 200 || /[\u0000-\u001f\u007f]/.test(name)) throw new Error('Invalid character image.');
  const contentType = mime(bytes), header = contentType && headerDimensions(bytes, contentType);
  if (!contentType || !header || header.width < 1 || header.height < 1 || header.width > 4096 || header.height > 4096) throw new Error('Choose a PNG or WebP image up to 4096 × 4096 pixels and 10 MB.');
  const dimensions = decode(bytes);
  if (!dimensions || dimensions.width !== header.width || dimensions.height !== header.height) throw new Error('The character image could not be decoded.');
  if (kind === 'sprite' && (dimensions.width % 4 !== 0 || dimensions.height % 3 !== 0 || dimensions.width / 4 < 16 || dimensions.height / 3 < 16)) {
    throw new Error('An animated sheet needs a 4 × 3 grid with cells at least 16 × 16 pixels.');
  }
  return { selection: 'custom', custom: { kind: kind as 'still' | 'sprite', dataUrl: `data:${contentType};base64,${bytes.toString('base64')}`, name } };
}
export class AppearanceStore {
  private state: AppearanceState = { selection: 'default' };
  revision = 0;
  constructor(private readonly root: string, private readonly decode: DecodeImage) {}
  current(): AppearanceState { return this.state; }
  async load(): Promise<void> {
    await directory(this.root);
    try {
      const profile = await readProfile(this.root) as Profile;
      if (profile.version !== 1) throw new Error('Unknown appearance version.');
      if ((BUILT_INS as readonly string[]).includes(profile.selection) && profile.custom === undefined) {
        this.state = { selection: profile.selection as BuiltIn }; return;
      }
      const c = profile.custom;
      if (profile.selection !== 'custom' || !c || typeof c.bytes !== 'string' || c.bytes.length > PROFILE_LIMIT ||
          !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(c.bytes)) throw new Error('Invalid appearance.');
      const bytes = Buffer.from(c.bytes, 'base64');
      if (mime(bytes) !== c.mime) throw new Error('Invalid image type.');
      this.state = customState(c.kind, bytes, c.name, this.decode);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') this.state = { selection: 'default' };
    }
  }
  async select(selection: unknown): Promise<void> {
    if (typeof selection !== 'string' || !(BUILT_INS as readonly string[]).includes(selection)) throw new Error('Unknown built-in character.');
    await writeProfile(this.root, { version: 1, selection });
    this.state = { selection: selection as BuiltIn }; this.revision++;
  }
  async importFile(file: string, kind: 'still' | 'sprite', name: string): Promise<void> {
    const before = await fs.lstat(file);
    if (!before.isFile() || before.isSymbolicLink() || before.size > MAX_CHARACTER_BYTES) throw new Error('Choose a regular PNG or WebP file up to 10 MB.');
    const handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0));
    let bytes: Buffer;
    try {
      const stat = await handle.stat();
      if (!stat.isFile() || stat.ino !== before.ino || stat.dev !== before.dev || stat.size > MAX_CHARACTER_BYTES) throw new Error('Character file changed. Choose it again.');
      const buffer = Buffer.alloc(MAX_CHARACTER_BYTES + 1), { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead > MAX_CHARACTER_BYTES) throw new Error('Character image is too large.');
      bytes = buffer.subarray(0, bytesRead);
    } finally { await handle.close(); }
    const state = customState(kind, bytes, name, this.decode);
    const contentType = mime(bytes)!;
    await writeProfile(this.root, { version: 1, selection: 'custom', custom: { kind, mime: contentType, bytes: bytes.toString('base64'), name } });
    this.state = state; this.revision++;
  }
}

// Standard VSIX ZIP packaging using Node built-ins. Runtime has no bundled npm dependencies.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
const xml = value => String(value).replace(/[<>&"']/g, character =>
  ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[character]);
const manifest = `<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="${xml(pkg.name)}" Version="${xml(pkg.version)}" Publisher="${xml(pkg.publisher)}"/>
    <DisplayName>${xml(pkg.displayName)}</DisplayName>
    <Description xml:space="preserve">${xml(pkg.description)}</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="${xml(pkg.engines.vscode)}"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/>
      <Property Id="Microsoft.VisualStudio.Code.ExecutesCode" Value="true"/>
      <Property Id="Microsoft.VisualStudio.Code.PreRelease" Value="false"/>
    </Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true"/>
  </Assets>
</PackageManifest>`;
const contentTypes = `<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json"/>
  <Default Extension="js" ContentType="application/javascript"/>
  <Default Extension="md" ContentType="text/markdown"/>
  <Default Extension="vsixmanifest" ContentType="text/xml"/>
  <Default Extension="txt" ContentType="text/plain"/>
</Types>`;
const files = [
  ['extension.vsixmanifest', Buffer.from(manifest)],
  ['[Content_Types].xml', Buffer.from(contentTypes)]
];
for (const name of ['package.json', 'README.md', 'NOTICE.txt', 'dist/src/extension.js',
                    'dist/src/protocol.js', 'dist/src/registry.js', 'dist/src/refresh.js', 'dist/src/codex.js',
                    'dist/src/windows-security.js']) {
  files.push([`extension/${name}`, await fs.readFile(path.join(root, name))]);
}
const crcTable = Array.from({ length: 256 }, (_, n) => {
  let crc = n;
  for (let bit = 0; bit < 8; bit += 1) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  return crc >>> 0;
});
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const value of buffer) crc = crcTable[(crc ^ value) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
const now = new Date();
const year = Math.max(1980, now.getUTCFullYear());
const dosDate = ((year - 1980) << 9) | ((now.getUTCMonth() + 1) << 5) | now.getUTCDate();
const dosTime = (now.getUTCHours() << 11) | (now.getUTCMinutes() << 5) | Math.floor(now.getUTCSeconds() / 2);
const entries = [], central = [];
let offset = 0;
for (const [name, data] of files) {
  const filename = Buffer.from(name);
  const compressed = deflateRawSync(data, { level: 9 });
  const checksum = crc32(data);
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x800, 6);
  local.writeUInt16LE(8, 8); local.writeUInt16LE(dosTime, 10); local.writeUInt16LE(dosDate, 12);
  local.writeUInt32LE(checksum, 14); local.writeUInt32LE(compressed.length, 18);
  local.writeUInt32LE(data.length, 22); local.writeUInt16LE(filename.length, 26);
  entries.push(local, filename, compressed);
  const header = Buffer.alloc(46);
  header.writeUInt32LE(0x02014b50, 0); header.writeUInt16LE(0x0314, 4); header.writeUInt16LE(20, 6);
  header.writeUInt16LE(0x800, 8); header.writeUInt16LE(8, 10);
  header.writeUInt16LE(dosTime, 12); header.writeUInt16LE(dosDate, 14);
  header.writeUInt32LE(checksum, 16); header.writeUInt32LE(compressed.length, 20);
  header.writeUInt32LE(data.length, 24); header.writeUInt16LE(filename.length, 28);
  header.writeUInt32LE((0o100644 << 16) >>> 0, 38); header.writeUInt32LE(offset, 42);
  central.push(header, filename);
  offset += local.length + filename.length + compressed.length;
}
const directory = Buffer.concat(central);
const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(files.length, 8); end.writeUInt16LE(files.length, 10);
end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
const destination = path.join(root, 'artifacts', `${pkg.name}-${pkg.version}.vsix`);
await fs.mkdir(path.dirname(destination), { recursive: true });
await fs.writeFile(destination, Buffer.concat([...entries, directory, end]));
console.log(destination);

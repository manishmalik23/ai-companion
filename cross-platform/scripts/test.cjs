const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const folder = path.join(__dirname, '../dist/tests');
const files = fs.readdirSync(folder).filter(name => name.endsWith('.test.js')).sort().map(name => path.join(folder, name));
if (!files.length) throw new Error('No compiled tests found.');
const result = spawnSync(process.execPath, ['--test', ...files], { stdio: 'inherit', shell: false });
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
